#!/usr/bin/env python3
"""
Deploy NixOS updates to all managed hosts with safe rollback.

Overview
--------
Every host is deployed using a safe pattern: arm a systemd watchdog timer,
activate the config with `nixos-rebuild test` (without persisting), verify
connectivity, then persist with `nixos-rebuild boot` and disarm the watchdog.
If any step fails, the watchdog reboots the host back to the last known-good
config. Use --no-safe to bypass this and use raw `nixos-rebuild switch`.

Before any deployment, `nix flake check` is run to catch evaluation errors
early (skip with --skip-flake-check). Then each host is deployed sequentially
in a fixed order.

Deploy order
------------
  1. k3s-node-1, k3s-node-2, k3s-node-3   (auto-reboot, k8s health check)
  2. framework-desktop                     (prompt reboot, k8s health check)
  3. microatx                              (prompt reboot)
  4. framework13-laptop                    (prompt reboot, opt-in only)
  5. router                                (never reboot, extended checks)

Safe deploy flow (all hosts)
-----------------------------
  1. Arm watchdog timer (systemd-run reboot on timeout)
  2. `nixos-rebuild test` — activate config without persisting
  3. Verify connectivity (with retries) — per-host checks:
       Default: SSH reachable + ping gateway from host
       Router:  SSH + ping internet + DNS + IPv6 tunnel + IPv6 internet
  4. `nixos-rebuild boot` — persist as boot default
  5. Disarm watchdog
  6. Handle reboot if kernel changed
  7. Post-deploy checks (k8s health)

  If step 2 or 3 fails, the watchdog reboots to the previous config.
  If step 4 fails, the config is active but not persisted; watchdog is
  disarmed and a warning is shown.

Failure handling
----------------
  - K3s node failure: hard stop remaining k3s group (cluster stability).
  - Other host failure: prompts whether to continue with remaining hosts.

Host groups
-----------
  k3s         k3s-node-1, k3s-node-2, k3s-node-3, framework-desktop
  infra       k3s-node-1, k3s-node-2, k3s-node-3, microatx, router
  workstation framework-desktop, framework13-laptop*
  router      router

Examples
--------
  deploy.py                              # deploy everything (safe mode)
  deploy.py --group k3s                  # just the k3s cluster + framework-desktop
  deploy.py --hosts router               # just the router
  deploy.py --hosts microatx framework-desktop   # specific hosts
  deploy.py --no-safe                    # bypass watchdog, use raw switch
  deploy.py --dry-run                    # verify without deploying
  deploy.py --force-reboot               # skip reboot prompts on PROMPT hosts
  deploy.py --reboot                     # force reboot even without kernel change
  deploy.py --no-reboot                  # never reboot (warn if needed)
  deploy.py --skip-flake-check           # skip nix flake check
  deploy.py --watchdog-timeout 600       # 10min watchdog instead of 5min
"""

import argparse
import builtins
import subprocess
import sys
import time
from dataclasses import dataclass, field
from enum import Enum

# Force all prints to flush immediately so output isn't buffered when piped/backgrounded
_builtin_print = builtins.print
def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _builtin_print(*args, **kwargs)


class RebootPolicy(Enum):
    AUTO = "auto"
    PROMPT = "prompt"
    NEVER = "never"


DEFAULT_CONNECTIVITY_CHECKS = ["ssh", "ping_gateway"]


@dataclass
class Host:
    hostname: str
    flake_name: str
    domain: str
    reboot_policy: RebootPolicy
    k8s_health_check: bool = False
    ssh_address: str | None = None
    deploy_order: int = 50
    groups: list[str] = field(default_factory=list)
    default: bool = True
    connectivity_checks: list[str] = field(default_factory=lambda: list(DEFAULT_CONNECTIVITY_CHECKS))

    @property
    def fqdn(self) -> str:
        if self.ssh_address:
            return self.ssh_address
        return f"{self.hostname}.{self.domain}" if self.domain else self.hostname


ALL_HOSTS = [
    Host("k3s-node-1", "k3s-node-1", "home.arpa",
         RebootPolicy.AUTO,
         k8s_health_check=True, deploy_order=10, groups=["k3s", "infra"],
         connectivity_checks=["ssh", "ping6_gateway"]),
    Host("k3s-node-2", "k3s-node-2", "home.arpa",
         RebootPolicy.AUTO,
         k8s_health_check=True, deploy_order=11, groups=["k3s", "infra"],
         connectivity_checks=["ssh", "ping6_gateway"]),
    Host("k3s-node-3", "k3s-node-3", "home.arpa",
         RebootPolicy.AUTO,
         k8s_health_check=True, deploy_order=12, groups=["k3s", "infra"],
         connectivity_checks=["ssh", "ping6_gateway"]),
    Host("framework-desktop", "framework-desktop", "home.arpa",
         RebootPolicy.PROMPT,
         deploy_order=20, groups=["workstation"]),
    Host("tarrasque", "tarrasque", "home.arpa",
         RebootPolicy.PROMPT,
         deploy_order=21, groups=["workstation"]),
    Host("microatx", "microatx", "home.arpa",
         RebootPolicy.PROMPT,
         deploy_order=30, groups=["infra"]),
Host("router", "router", "",
         RebootPolicy.NEVER,
         ssh_address="10.28.0.1", deploy_order=99, groups=["infra", "router"],
         connectivity_checks=["ssh", "ping_internet", "dns", "ipv6_tunnel", "ipv6_internet"]),
    Host("framework13-laptop", "framework13-laptop", "",
         RebootPolicy.PROMPT,
         deploy_order=40, groups=["workstation"],
         connectivity_checks=["ssh"],
         default=False),
]

deploy_warnings: list[str] = []

SSH_TIMEOUT = 10
REBOOT_WAIT_INITIAL = 30
REBOOT_WAIT_INTERVAL = 10
REBOOT_WAIT_MAX = 300
NODE_HEALTH_RETRIES = 12
NODE_HEALTH_INTERVAL = 10
VERIFY_RETRIES = 3
VERIFY_RETRY_DELAY = 2
DEPLOY_TIMEOUT = 60

# Host to offload eval+build to via nixos-rebuild --build-host.
# nixos-rebuild-ng evaluates and builds on this host, saving laptop CPU.
# Used unconditionally (even when deploying BUILD_HOST itself); aarch64
# targets are handled via tarrasque's existing binfmt emulation.
BUILD_HOST = "tarrasque"


def build_host_args(args: argparse.Namespace) -> list[str]:
    """Return build-offload flags unless --no-build-host was passed.

    --use-substitutes makes the target pull paths from its configured
    substituters (harmonia on BUILD_HOST) instead of having this laptop
    proxy them in the nix-copy step."""
    if args.no_build_host:
        return []
    return ["--build-host", BUILD_HOST, "--use-substitutes"]


def run_cmd(
    cmd: list[str],
    check: bool = True,
    capture_output: bool = False,
    timeout: int | None = None,
) -> subprocess.CompletedProcess:
    """Run a command and optionally check for errors."""
    print(f"  Running: {' '.join(cmd)}")
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture_output,
        text=True,
        timeout=timeout,
    )


def ssh_cmd(host: Host, cmd: str, timeout: int = SSH_TIMEOUT) -> subprocess.CompletedProcess:
    """Run a command on a remote host via SSH."""
    return run_cmd(
        ["ssh", "-o", f"ConnectTimeout={timeout}", "-o", "BatchMode=yes", host.fqdn, cmd],
        capture_output=True,
        timeout=timeout + 5,
    )


def check_ssh(host: Host) -> bool:
    """Verify SSH connectivity to a host."""
    print(f"  Checking SSH connectivity to {host.fqdn}...")
    try:
        result = ssh_cmd(host, "echo ok")
        if result.returncode == 0 and "ok" in result.stdout:
            print(f"  ✓ SSH to {host.fqdn} works")
            return True
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as e:
        print(f"  ✗ SSH to {host.fqdn} failed: {e}")
    return False


def get_running_kernel(host: Host) -> str | None:
    try:
        result = ssh_cmd(host, "uname -r")
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def get_new_kernel(host: Host) -> str | None:
    try:
        result = ssh_cmd(host, "ls /run/current-system/kernel-modules/lib/modules/")
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def get_booted_kernel_params(host: Host) -> set[str] | None:
    try:
        result = ssh_cmd(host, "cat /run/booted-system/kernel-params")
        if result.returncode == 0:
            return set(result.stdout.strip().split())
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def get_new_kernel_params(host: Host) -> set[str] | None:
    try:
        result = ssh_cmd(host, "cat /run/current-system/kernel-params")
        if result.returncode == 0:
            return set(result.stdout.strip().split())
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def needs_reboot(host: Host) -> bool:
    """Check if a host needs a reboot (kernel version or parameters changed)."""
    needs = False

    running_kernel = get_running_kernel(host)
    new_kernel = get_new_kernel(host)
    if running_kernel and new_kernel and running_kernel != new_kernel:
        print(f"  Reboot needed: running kernel={running_kernel} != new kernel={new_kernel}")
        needs = True

    booted_params = get_booted_kernel_params(host)
    new_params = get_new_kernel_params(host)
    if booted_params and new_params and booted_params != new_params:
        added = new_params - booted_params
        removed = booted_params - new_params
        print(f"  Reboot needed: kernel parameters changed")
        if added:
            print(f"    Added: {added}")
        if removed:
            print(f"    Removed: {removed}")
        needs = True

    return needs


def get_node_status(hostname: str) -> tuple[bool, str]:
    """Check if a kubernetes node is ready."""
    try:
        result = run_cmd(
            ["kubectl", "get", "node", hostname,
             "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"],
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            status = result.stdout.strip()
            return status == "True", status
        return False, f"kubectl failed: {result.stderr}"
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        return False, "kubectl not found"


def wait_for_node_healthy(host: Host) -> bool:
    """Wait for a kubernetes node to become healthy."""
    print(f"  Waiting for node {host.hostname} to become healthy...")
    for i in range(NODE_HEALTH_RETRIES):
        is_ready, status = get_node_status(host.hostname)
        if is_ready:
            print(f"  ✓ Node {host.hostname} is Ready")
            return True
        print(f"  Node {host.hostname} status: {status} (attempt {i + 1}/{NODE_HEALTH_RETRIES})")
        if i < NODE_HEALTH_RETRIES - 1:
            time.sleep(NODE_HEALTH_INTERVAL)
    print(f"  ✗ Node {host.hostname} did not become healthy")
    return False


def wait_for_host_online(host: Host) -> bool:
    """Wait for a host to come back online after reboot."""
    print(f"  Waiting {REBOOT_WAIT_INITIAL}s for {host.fqdn} to start rebooting...")
    time.sleep(REBOOT_WAIT_INITIAL)

    start_time = time.time()
    while time.time() - start_time < REBOOT_WAIT_MAX:
        if check_ssh(host):
            return True
        print(f"  Host {host.fqdn} not yet reachable, waiting {REBOOT_WAIT_INTERVAL}s...")
        time.sleep(REBOOT_WAIT_INTERVAL)

    print(f"  ✗ Host {host.fqdn} did not come back online within {REBOOT_WAIT_MAX}s")
    return False


def reboot_host(host: Host) -> bool:
    """Reboot a host and wait for it to come back online."""
    print(f"  Rebooting {host.fqdn}...")
    try:
        run_cmd(
            ["ssh", "-o", f"ConnectTimeout={SSH_TIMEOUT}", host.fqdn,
             "sudo systemctl reboot"],
            check=False,
            capture_output=True,
        )
    except subprocess.TimeoutExpired:
        pass  # Expected — connection drops during reboot

    return wait_for_host_online(host)


def handle_reboot(host: Host, force_reboot: bool, no_reboot: bool,
                  force_reboot_prompt: bool, assume_needed: bool = False) -> bool:
    """Decide whether to reboot based on host policy and flags.

    Returns False only if a reboot was attempted and failed.

    assume_needed: skip the needs_reboot() check and treat reboot as required.
    Used by --boot-only mode where /run/current-system isn't updated, so the
    kernel-vs-running comparison can't detect that the new generation needs a
    reboot to take effect."""
    if force_reboot:
        print(f"  Forcing reboot due to --reboot flag")
        return reboot_host(host)

    if not assume_needed and not needs_reboot(host):
        print(f"  No reboot needed for {host.hostname}")
        return True

    # Reboot is needed
    if no_reboot:
        msg = f"{host.hostname} needs reboot (skipped due to --no-reboot)"
        print(f"  ⚠ {msg}")
        deploy_warnings.append(msg)
        return True

    if host.reboot_policy == RebootPolicy.AUTO or force_reboot_prompt:
        return reboot_host(host)

    if host.reboot_policy == RebootPolicy.PROMPT:
        answer = input(f"  Reboot {host.hostname}? [y/N]: ").strip().lower()
        if answer == "y":
            return reboot_host(host)
        msg = f"{host.hostname} needs reboot (user declined)"
        print(f"  ⚠ {msg}")
        deploy_warnings.append(msg)
        return True

    # NEVER policy
    msg = f"{host.hostname} needs reboot (policy is NEVER, reboot manually)"
    print(f"  ⚠ {msg}")
    deploy_warnings.append(msg)
    return True



def get_expected_system_path(host: Host) -> str | None:
    """Eval-only query for the expected system store path. Does not build or
    fetch — relies on the eval cache populated by an earlier nixos-rebuild."""
    try:
        result = run_cmd(
            ["nix", "eval", "--raw",
             f".#nixosConfigurations.{host.flake_name}.config.system.build.toplevel.outPath"],
            capture_output=True, check=True,
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def get_active_system_path(host: Host) -> str | None:
    """Get the currently active system store path on a remote host."""
    try:
        result = ssh_cmd(host, "readlink /run/current-system", timeout=10)
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def verify_config_active(host: Host, expected_path: str) -> bool:
    """Verify the expected config is actually running on the host."""
    active = get_active_system_path(host)
    if active is None:
        print(f"  ✗ Could not read active system path from {host.hostname}")
        return False
    if active == expected_path:
        print(f"  ✓ Config verified active: {expected_path}")
        return True
    print(f"  ✗ Config mismatch! Expected:\n      {expected_path}\n    Active:\n      {active}")
    print(f"  Host may have rebooted (watchdog?) — refusing to persist")
    return False


def build_host(host: Host, args: argparse.Namespace) -> str | None:
    """Build the NixOS configuration for a host (no activation).
    Returns the expected system store path, or None on failure.

    When offloading to BUILD_HOST, also passes --target-host so the closure
    is copied build-host -> target directly, instead of being pulled back to
    this laptop. With --no-build-host, builds locally as before."""
    print(f"  Building config for {host.fqdn}...")
    cmd = [
        "nixos-rebuild", "build",
        "--flake", f".#{host.flake_name}",
        "--no-reexec",
    ] + build_host_args(args)
    if not args.no_build_host:
        cmd += ["--target-host", host.fqdn, "--sudo"]
    try:
        run_cmd(cmd)
    except subprocess.CalledProcessError as e:
        print(f"  ✗ Build for {host.fqdn} failed: {e}")
        return None
    path = get_expected_system_path(host)
    if path:
        print(f"  ✓ Build for {host.fqdn} succeeded: {path}")
    else:
        print(f"  ✗ Build succeeded but could not determine system path")
    return path


def clear_nixos_rebuild_unit(host: Host) -> None:
    """Clear the nixos-rebuild-switch-to-configuration unit on a remote host.
    Called after a timed-out 'test' leaves a stale unit that blocks subsequent runs."""
    print(f"  Clearing stale nixos-rebuild unit on {host.hostname}...")
    for action in ["stop", "reset-failed"]:
        try:
            ssh_cmd(host, f"sudo systemctl {action} nixos-rebuild-switch-to-configuration.service",
                    timeout=10)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            pass


def deploy_host(host: Host, args: argparse.Namespace,
                mode: str = "switch", timeout: int = DEPLOY_TIMEOUT) -> bool:
    """Deploy NixOS configuration to a host with the given mode (switch/test/boot).

    Assumes the config is already built locally (via build_host). The timeout
    only covers the copy + remote activation, not the build. If the command
    times out or the SSH connection drops during 'test' mode (common when
    sysinit-reactivation.target restarts networkd mid-activation), and the host
    is still reachable via SSH, the activation likely succeeded.
    Sets host._test_timed_out so the caller can clear the unit before 'boot'.
    """
    print(f"  Deploying ({mode}) to {host.fqdn}...")
    env = {
        **__import__('os').environ,
        # ServerAliveInterval causes SSH to detect a dead control socket in
        # ~15s instead of waiting for the OS TCP timeout (~minutes).
        "NIX_SSHOPTS": "-o ServerAliveInterval=5 -o ServerAliveCountMax=3",
    }
    cmd = ["nixos-rebuild", mode,
           "--target-host", host.fqdn,
           "--flake", f".#{host.flake_name}",
           "--no-reexec",
           "--sudo"] + build_host_args(args)
    try:
        print(f"  Running: {' '.join(cmd)}")
        subprocess.run(
            cmd,
            check=True,
            timeout=timeout,
            env=env,
        )
        print(f"  ✓ Deployment ({mode}) to {host.fqdn} succeeded")
        return True
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as e:
        if mode == "test":
            # SSH may have died when sysinit-reactivation.target restarted network
            # services mid-activation. Wait briefly for the host to settle, then
            # check reachability — if SSH is up, activation almost certainly succeeded.
            time.sleep(5)
            if check_ssh(host):
                print(f"  ⚠ Deployment ({mode}) disconnected but host is reachable — assuming activation succeeded")
                host._test_timed_out = True
                return True
        if isinstance(e, subprocess.TimeoutExpired):
            print(f"  ✗ Deployment ({mode}) to {host.fqdn} timed out after {timeout}s")
        else:
            print(f"  ✗ Deployment ({mode}) to {host.fqdn} failed: {e}")
        return False


def build_flake(host: Host, args: argparse.Namespace) -> bool:
    """Build the flake for a host without deploying."""
    print(f"  Building flake for {host.flake_name}...")
    try:
        run_cmd([
            "nixos-rebuild", "build",
            "--flake", f".#{host.flake_name}",
            "--no-reexec",
        ] + build_host_args(args))
        print(f"  ✓ Flake for {host.flake_name} builds successfully")
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ✗ Flake for {host.flake_name} failed to build: {e}")
        return False


def ping_check(target: str, via_host: str | None = None) -> bool:
    """Ping a target and return True if reachable.
    If via_host is given, run the ping on that host via SSH."""
    try:
        if via_host:
            cmd = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
                   via_host, "ping", "-c", "3", "-W", "5", target]
        else:
            cmd = ["ping", "-c", "3", "-W", "5", target]
        result = run_cmd(
            cmd,
            capture_output=True, check=False, timeout=20,
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def dns_check() -> bool:
    """Check that DNS resolution works (uses getent, no extra deps)."""
    try:
        result = run_cmd(
            ["getent", "hosts", "google.com"],
            capture_output=True, check=False, timeout=10,
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def ping6_check(target: str, via_host: str | None = None) -> bool:
    """Ping an IPv6 target and return True if reachable.
    If via_host is given, run the ping on that host via SSH."""
    try:
        if via_host:
            cmd = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
                   via_host, "ping", "-6", "-c", "3", "-W", "5", target]
        else:
            cmd = ["ping", "-6", "-c", "3", "-W", "5", target]
        result = run_cmd(
            cmd,
            capture_output=True, check=False, timeout=20,
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def verify_host_connectivity(host: Host) -> bool:
    """Run per-host connectivity checks with retries to handle networkd settling."""
    check_map = {
        "ssh": ("SSH", lambda: check_ssh(host)),
        "ping_gateway": ("Ping gateway", lambda: ping_check("10.28.0.1", via_host=host.fqdn)),
        "ping6_gateway": ("Ping6 gateway", lambda: ping6_check("2001:470:482f::1", via_host=host.fqdn)),
        "ping_internet": ("Ping internet (1.1.1.1)", lambda: ping_check("1.1.1.1")),
        "dns": ("DNS resolution", dns_check),
        "ipv6_tunnel": ("IPv6 tunnel (HE)", lambda: ping6_check("2001:470:66:35::1", via_host=host.ssh_address)),
        "ipv6_internet": ("IPv6 internet", lambda: ping6_check("2001:4860:4860::8888", via_host=host.ssh_address)),
    }

    for attempt in range(VERIFY_RETRIES):
        all_ok = True
        for check_name in host.connectivity_checks:
            label, check_fn = check_map[check_name]
            try:
                if check_fn():
                    print(f"    ✓ {label}")
                else:
                    print(f"    ✗ {label}: FAILED")
                    all_ok = False
                    break
            except Exception as e:
                print(f"    ✗ {label}: ERROR ({e})")
                all_ok = False
                break
        if all_ok:
            return True
        if attempt < VERIFY_RETRIES - 1:
            print(f"  Connectivity check failed, retrying in {VERIFY_RETRY_DELAY}s ({attempt + 1}/{VERIFY_RETRIES})...")
            time.sleep(VERIFY_RETRY_DELAY)
    return False


def arm_watchdog(host: Host, timeout: int) -> str | None:
    """Arm a systemd watchdog timer on a host. Returns unit name or None."""
    unit_name = f"deploy-watchdog-{int(time.time())}"
    print(f"  Arming watchdog timer ({timeout}s) on {host.fqdn} [unit={unit_name}]...")
    try:
        ssh_cmd(
            host,
            f"sudo systemd-run --unit={unit_name} --on-active={timeout}s systemctl reboot",
            timeout=30,
        )
        print(f"  ✓ Watchdog armed")
        return unit_name
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as e:
        print(f"  ✗ Could not arm watchdog: {e}")
        return None


def disarm_watchdog(host: Host, unit_name: str) -> None:
    """Cancel the watchdog timer on a host."""
    print(f"  Disarming watchdog timer [{unit_name}]...")
    for suffix in [".timer", ""]:
        try:
            ssh_cmd(host, f"sudo systemctl stop {unit_name}{suffix}", timeout=30)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            pass
    print(f"  Watchdog disarmed")


def deploy_safe(host: Host, args: argparse.Namespace) -> bool:
    """Deploy safely: build, arm watchdog, test, verify connectivity, boot, disarm."""
    watchdog_timeout = args.watchdog_timeout
    deploy_timeout = args.deploy_timeout

    print(f"\n  [1/8] Building locally...")
    expected_path = build_host(host, args)
    if not expected_path:
        return False

    # Clear any stale nixos-rebuild unit from a previous failed deploy
    clear_nixos_rebuild_unit(host)

    print(f"\n  [2/8] Arming watchdog ({watchdog_timeout}s)...")
    unit_name = arm_watchdog(host, watchdog_timeout)
    if unit_name is None:
        print(f"  FATAL: Cannot proceed without watchdog protection")
        return False

    print(f"\n  [3/8] Activating config (nixos-rebuild test)...")
    if not deploy_host(host, args, mode="test", timeout=deploy_timeout):
        print(f"  'nixos-rebuild test' failed.")
        print(f"  Watchdog will reboot {host.hostname} in <={watchdog_timeout}s to restore old config")
        return False

    print(f"\n  [4/8] Verifying connectivity...")
    if not verify_host_connectivity(host):
        print(f"  Connectivity checks FAILED after 'nixos-rebuild test'")
        print(f"  Watchdog will reboot {host.hostname} in <={watchdog_timeout}s to restore old config")
        return False

    print(f"\n  [5/8] Verifying active config matches build...")
    if not verify_config_active(host, expected_path):
        print(f"  Watchdog will reboot {host.hostname} in <={watchdog_timeout}s to restore old config")
        return False

    print(f"\n  [6/8] Persisting config (nixos-rebuild boot)...")
    if getattr(host, '_test_timed_out', False):
        clear_nixos_rebuild_unit(host)
    if not deploy_host(host, args, mode="boot", timeout=deploy_timeout):
        print(f"  'nixos-rebuild boot' failed! Config is active but NOT persisted as boot default.")
        disarm_watchdog(host, unit_name)
        return False

    print(f"\n  [7/8] Disarming watchdog...")
    disarm_watchdog(host, unit_name)

    print(f"\n  [8/8] Post-deploy checks...")
    if not handle_reboot(host, force_reboot=args.reboot, no_reboot=args.no_reboot,
                         force_reboot_prompt=args.force_reboot):
        return False

    if host.k8s_health_check and not args.skip_k8s_check:
        if not wait_for_node_healthy(host):
            return False

    print(f"\n  ✓ {host.hostname} deployed and persisted successfully")
    return True


def deploy_unsafe(host: Host, args: argparse.Namespace, mode: str = "switch") -> bool:
    """Deploy without watchdog protection. mode is 'switch' (build+activate+
    persist) or 'boot' (build+persist only, no activation — for changes that
    require a reboot to take effect, e.g. dbus implementation switch)."""
    if not build_host(host, args):  # returns path or None
        return False

    if not deploy_host(host, args, mode=mode, timeout=args.deploy_timeout):
        return False

    if not handle_reboot(host, force_reboot=args.reboot, no_reboot=args.no_reboot,
                         force_reboot_prompt=args.force_reboot,
                         assume_needed=(mode == "boot")):
        return False

    if host.k8s_health_check and not args.skip_k8s_check:
        if not wait_for_node_healthy(host):
            return False

    print(f"  ✓ {host.hostname} deployed successfully (no-safe, {mode})")
    return True


def process_host(host: Host, args: argparse.Namespace) -> bool:
    """Deploy a host using the safe (watchdog) or unsafe (switch/boot) flow."""
    if args.boot_only:
        mode = "no-safe boot"
    elif args.no_safe:
        mode = "no-safe switch"
    else:
        mode = "safe"
    print(f"\n{'=' * 60}")
    print(f"Processing {host.hostname} (mode={mode}, reboot={host.reboot_policy.value})")
    print(f"{'=' * 60}")

    if not check_ssh(host):
        return False

    if args.dry_run:
        return process_host_dry_run(host, args)

    if args.boot_only:
        return deploy_unsafe(host, args, mode="boot")
    if args.no_safe:
        return deploy_unsafe(host, args, mode="switch")
    return deploy_safe(host, args)


def process_host_dry_run(host: Host, args: argparse.Namespace) -> bool:
    """Dry-run: verify SSH (already done), systemd-run, k8s health, flake build."""
    print(f"  [DRY-RUN] Checking {host.hostname}...")

    if host.k8s_health_check:
        is_ready, status = get_node_status(host.hostname)
        if is_ready:
            print(f"  ✓ Node {host.hostname} is healthy (Ready)")
        else:
            print(f"  ✗ Node {host.hostname} is not healthy: {status}")
            return False

    try:
        result = ssh_cmd(host, "which systemd-run", timeout=10)
        if result.returncode == 0:
            print(f"  ✓ systemd-run available on {host.hostname}")
        else:
            print(f"  ✗ systemd-run not found on {host.hostname}")
            return False
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as e:
        print(f"  ✗ Could not check systemd-run on {host.hostname}: {e}")
        return False

    if not build_flake(host, args):
        return False

    print(f"  ✓ [DRY-RUN] {host.hostname} passed all checks")
    return True


def filter_hosts(hosts: list[Host], hostnames: list[str] | None,
                 groups: list[str] | None) -> list[Host]:
    """Filter and sort hosts by --hosts and --group flags."""
    filtered = list(hosts)
    if hostnames:
        filtered = [h for h in filtered if h.hostname in hostnames]
    elif groups:
        filtered = [h for h in filtered if any(g in h.groups for g in groups)]
    else:
        filtered = [h for h in filtered if h.default]
    filtered.sort(key=lambda h: h.deploy_order)
    return filtered


def run_flake_check() -> bool:
    """Run nix flake check and return True if it passes."""
    print("Running nix flake check...")
    try:
        run_cmd(["nix", "flake", "check", "."])
        print("  ✓ Flake check passed")
        return True
    except subprocess.CalledProcessError:
        print("  ✗ Flake check FAILED")
        return False


def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser."""
    parser = argparse.ArgumentParser(
        description="Deploy NixOS updates to managed hosts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Don't deploy or reboot; verify SSH, health, and flake builds",
    )
    parser.add_argument(
        "--no-reboot",
        action="store_true",
        help="Skip rebooting hosts even if updates require it",
    )
    parser.add_argument(
        "--reboot",
        action="store_true",
        help="Always reboot after deployment, even if no kernel update occurred",
    )
    parser.add_argument(
        "--force-reboot",
        action="store_true",
        help="Override PROMPT reboot policy to reboot without asking (does not affect NEVER)",
    )
    parser.add_argument(
        "--hosts",
        nargs="+",
        metavar="HOSTNAME",
        help="Only process specific hosts (by hostname)",
    )
    parser.add_argument(
        "--group",
        nargs="+",
        metavar="GROUP",
        help="Only process hosts in specific groups (k3s, infra, workstation, router)",
    )
    parser.add_argument(
        "--skip-flake-check",
        action="store_true",
        help="Skip the initial nix flake check",
    )
    parser.add_argument(
        "--no-safe",
        action="store_true",
        help="Bypass watchdog protection; use raw nixos-rebuild switch",
    )
    parser.add_argument(
        "--boot-only",
        action="store_true",
        help="Bypass watchdog and use nixos-rebuild boot (no activation, just persist as next boot). Use for changes that require a reboot to take effect, e.g. dbus implementation switch.",
    )
    parser.add_argument(
        "--watchdog-timeout",
        type=int,
        default=300,
        help="Watchdog timeout in seconds (default: 300)",
    )
    parser.add_argument(
        "--deploy-timeout",
        type=int,
        default=DEPLOY_TIMEOUT,
        help=f"Timeout for each nixos-rebuild command in seconds (default: {DEPLOY_TIMEOUT})",
    )
    parser.add_argument(
        "--skip-k8s-check",
        action="store_true",
        help="Skip the post-deploy k8s node health check",
    )
    parser.add_argument(
        "--no-build-host",
        action="store_true",
        help=f"Disable eval+build offload to {BUILD_HOST}; run everything locally",
    )
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    # Validate mutually exclusive reboot options
    if args.reboot and args.no_reboot:
        print("Error: --reboot and --no-reboot cannot be used together")
        sys.exit(1)
    if args.no_safe and args.boot_only:
        print("Error: --no-safe and --boot-only cannot be used together")
        sys.exit(1)

    # Filter and sort hosts
    hosts = filter_hosts(ALL_HOSTS, args.hosts, args.group)
    if not hosts:
        all_names = [h.hostname for h in ALL_HOSTS]
        all_groups = sorted(set(g for h in ALL_HOSTS for g in h.groups))
        print(f"Error: No matching hosts found")
        print(f"Available hosts: {all_names}")
        print(f"Available groups: {all_groups}")
        sys.exit(1)

    # Print plan
    print(f"Hosts ({len(hosts)}): {[h.hostname for h in hosts]}")
    print(f"Mode: {'DRY-RUN' if args.dry_run else 'DEPLOY'}")
    if args.no_reboot:
        print("Reboot: DISABLED")
    elif args.reboot:
        print("Reboot: FORCED")
    elif args.force_reboot:
        print("Reboot: FORCE-PROMPT (skip confirmation)")

    # Flake check
    if not args.skip_flake_check and not args.dry_run:
        if not run_flake_check():
            sys.exit(1)

    # Verify build host is reachable; we offload eval+build to it.
    if not args.no_build_host:
        print(f"\nChecking build host {BUILD_HOST} is reachable...")
        probe = subprocess.run(
            ["ssh", "-o", f"ConnectTimeout={SSH_TIMEOUT}", "-o", "BatchMode=yes",
             BUILD_HOST, "true"],
            capture_output=True,
        )
        if probe.returncode != 0:
            print(f"  ✗ Build host {BUILD_HOST} unreachable. Aborting.")
            print(f"    stderr: {probe.stderr.decode().strip()}")
            print(f"    (rerun with --no-build-host to build locally)")
            sys.exit(1)
        print(f"  ✓ Build host {BUILD_HOST} reachable")

    # Deploy
    failed_hosts = []
    for host in hosts:
        success = process_host(host, args)

        if not success:
            failed_hosts.append(host.hostname)

            if "k3s" in host.groups:
                print(f"\n✗ K3s rolling deploy failed at {host.hostname}, stopping.")
                break
            else:
                answer = input(
                    f"\n✗ {host.hostname} failed. Continue with remaining hosts? [y/N]: "
                ).strip().lower()
                if answer != "y":
                    break

    # Summary
    print(f"\n{'=' * 60}")
    print("Summary")
    print(f"{'=' * 60}")

    if deploy_warnings:
        print("\nWarnings:")
        for warning in deploy_warnings:
            print(f"  ⚠ {warning}")

    if failed_hosts:
        print(f"\nFailed hosts: {failed_hosts}")
        sys.exit(1)
    else:
        print("\nAll hosts processed successfully!")
        sys.exit(0)


if __name__ == "__main__":
    main()
