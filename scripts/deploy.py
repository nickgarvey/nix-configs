#!/usr/bin/env python3
"""
Deploy NixOS updates to all managed hosts with per-host strategies.

Overview
--------
Each host has a deploy strategy and reboot policy configured in the host
registry (ALL_HOSTS). The script deploys hosts sequentially in a fixed
order so that the least-critical-to-lose hosts are updated last.

Before any deployment, `nix flake check` is run to catch evaluation errors
early (skip with --skip-flake-check). Then each host is deployed according
to its strategy.

Deploy order and strategies
---------------------------
  1. k3s-node-1, k3s-node-2, k3s-node-3  [ROLLING_K3S]
     - `nixos-rebuild switch` to each node one at a time
     - Auto-reboots if kernel or kernel params changed (no prompt)
     - Waits for the k8s node to report Ready before moving to the next
     - Any failure hard-stops the entire k3s group

  2. framework                            [STANDARD]
     - `nixos-rebuild switch`
     - Prompts before reboot (override with --force-reboot)
     - Waits for k8s node Ready (it is a k3s agent)

  3. microatx                             [STANDARD]
     - `nixos-rebuild switch`
     - Prompts before reboot (override with --force-reboot)
     - No k8s health check

  4. framework13-laptop                   [STANDARD] (opt-in only)
     - `nixos-rebuild switch`
     - Prompts before reboot (override with --force-reboot)
     - No k8s health check
     - NOT deployed by default; specify with --hosts framework13-laptop

  5. router                               [ROUTER_SAFE]
     - Arms a systemd watchdog timer on the router via SSH. If the deploy
       breaks networking, the watchdog reboots the router after the timeout
       (default 300s), restoring the previous boot config automatically.
     - `nixos-rebuild test` activates the new config WITHOUT setting it as
       the boot default.
     - Runs connectivity checks: SSH to router, ping 1.1.1.1, DNS.
     - If checks pass: `nixos-rebuild boot` persists the config as the boot
       default, then disarms the watchdog.
     - If checks fail: the script exits and the watchdog reboots the router,
       which boots back into the old (known-good) config.

Failure handling
----------------
  - K3s node failure: hard stop (cluster stability).
  - Other host failure: prompts whether to continue with remaining hosts.

Host groups
-----------
  k3s         k3s-node-1, k3s-node-2, k3s-node-3, framework
  infra       k3s-node-1, k3s-node-2, k3s-node-3, microatx, router
  workstation framework, framework13-laptop*
  router      router

Dry-run mode (--dry-run)
------------------------
  - Verifies SSH connectivity to each host
  - Checks k8s node health (for k8s hosts)
  - Checks systemd-run availability (for router)
  - Builds the flake for each host (without deploying)

Examples
--------
  deploy.py                              # deploy everything
  deploy.py --group k3s                  # just the k3s cluster + framework
  deploy.py --hosts router               # just the router
  deploy.py --hosts microatx framework   # specific hosts
  deploy.py --dry-run                    # verify without deploying
  deploy.py --force-reboot               # skip reboot prompts on PROMPT hosts
  deploy.py --reboot                     # force reboot even without kernel change
  deploy.py --no-reboot                  # never reboot (warn if needed)
  deploy.py --skip-flake-check           # skip nix flake check
  deploy.py --router-watchdog-timeout 600  # 10min watchdog instead of 5min
"""

import argparse
import subprocess
import sys
import time
from dataclasses import dataclass, field
from enum import Enum


class DeployStrategy(Enum):
    ROLLING_K3S = "rolling_k3s"
    STANDARD = "standard"
    ROUTER_SAFE = "router_safe"


class RebootPolicy(Enum):
    AUTO = "auto"
    PROMPT = "prompt"
    NEVER = "never"


@dataclass
class Host:
    hostname: str
    flake_name: str
    domain: str
    deploy_strategy: DeployStrategy
    reboot_policy: RebootPolicy
    k8s_health_check: bool = False
    ssh_address: str | None = None
    deploy_order: int = 50
    groups: list[str] = field(default_factory=list)
    default: bool = True

    @property
    def fqdn(self) -> str:
        if self.ssh_address:
            return self.ssh_address
        return f"{self.hostname}.{self.domain}" if self.domain else self.hostname


ALL_HOSTS = [
    Host("k3s-node-1", "k3s-node-1", "home.arpa",
         DeployStrategy.ROLLING_K3S, RebootPolicy.AUTO,
         k8s_health_check=True, deploy_order=10, groups=["k3s", "infra"]),
    Host("k3s-node-2", "k3s-node-2", "home.arpa",
         DeployStrategy.ROLLING_K3S, RebootPolicy.AUTO,
         k8s_health_check=True, deploy_order=11, groups=["k3s", "infra"]),
    Host("k3s-node-3", "k3s-node-3", "home.arpa",
         DeployStrategy.ROLLING_K3S, RebootPolicy.AUTO,
         k8s_health_check=True, deploy_order=12, groups=["k3s", "infra"]),
    Host("framework", "framework", "",
         DeployStrategy.STANDARD, RebootPolicy.PROMPT,
         k8s_health_check=True, deploy_order=20, groups=["k3s", "workstation"]),
    Host("microatx", "microatx", "home.arpa",
         DeployStrategy.STANDARD, RebootPolicy.PROMPT,
         k8s_health_check=False, deploy_order=30, groups=["infra"]),
    Host("router", "router", "",
         DeployStrategy.ROUTER_SAFE, RebootPolicy.NEVER,
         ssh_address="10.28.0.1", deploy_order=99, groups=["infra", "router"]),
    Host("framework13-laptop", "framework13-laptop", "",
         DeployStrategy.STANDARD, RebootPolicy.PROMPT,
         k8s_health_check=False, deploy_order=40, groups=["workstation"],
         default=False),
]

deploy_warnings: list[str] = []

SSH_TIMEOUT = 10
REBOOT_WAIT_INITIAL = 30
REBOOT_WAIT_INTERVAL = 10
REBOOT_WAIT_MAX = 300
NODE_HEALTH_RETRIES = 12
NODE_HEALTH_INTERVAL = 10
ROUTER_STABILIZE_WAIT = 10

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
                  force_reboot_prompt: bool) -> bool:
    """Decide whether to reboot based on host policy and flags.

    Returns False only if a reboot was attempted and failed.
    """
    if force_reboot:
        print(f"  Forcing reboot due to --reboot flag")
        return reboot_host(host)

    if not needs_reboot(host):
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


def deploy_host(host: Host, mode: str = "switch") -> bool:
    """Deploy NixOS configuration to a host with the given mode (switch/test/boot)."""
    print(f"  Deploying ({mode}) to {host.fqdn}...")
    try:
        run_cmd([
            "nixos-rebuild", mode,
            "--target-host", host.fqdn,
            "--flake", f".#{host.flake_name}",
            "--no-reexec",
            "--sudo",
        ])
        print(f"  ✓ Deployment ({mode}) to {host.fqdn} succeeded")
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ✗ Deployment ({mode}) to {host.fqdn} failed: {e}")
        return False


def build_flake(host: Host) -> bool:
    """Build the flake for a host without deploying."""
    print(f"  Building flake for {host.flake_name}...")
    try:
        run_cmd([
            "nix", "build",
            f".#nixosConfigurations.{host.flake_name}.config.system.build.toplevel",
            "--no-link",
        ])
        print(f"  ✓ Flake for {host.flake_name} builds successfully")
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ✗ Flake for {host.flake_name} failed to build: {e}")
        return False


def ping_check(target: str) -> bool:
    """Ping a target and return True if reachable."""
    try:
        result = run_cmd(
            ["ping", "-c", "3", "-W", "5", target],
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


def verify_router_connectivity(host: Host) -> bool:
    """Run connectivity checks after a router config change."""
    checks = [
        ("SSH to router", lambda: check_ssh(host)),
        ("Ping internet (1.1.1.1)", lambda: ping_check("1.1.1.1")),
        ("DNS resolution", dns_check),
        ("IPv6 tunnel (HE)", lambda: ping6_check("2001:470:66:35::1", via_host=host.ssh_address)),
        ("IPv6 internet", lambda: ping6_check("2001:4860:4860::8888", via_host=host.ssh_address)),
    ]
    all_ok = True
    for name, check_fn in checks:
        try:
            if check_fn():
                print(f"    ✓ {name}")
            else:
                print(f"    ✗ {name}: FAILED")
                all_ok = False
        except Exception as e:
            print(f"    ✗ {name}: ERROR ({e})")
            all_ok = False
    return all_ok


def arm_watchdog(host: Host, timeout: int) -> str | None:
    """Arm a systemd watchdog timer on the router. Returns unit name or None."""
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
    """Cancel the watchdog timer on the router."""
    print(f"  Disarming watchdog timer [{unit_name}]...")
    for suffix in [".timer", ""]:
        try:
            ssh_cmd(host, f"sudo systemctl stop {unit_name}{suffix}", timeout=30)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            pass
    print(f"  Watchdog disarmed")


def deploy_rolling_k3s(host: Host, args: argparse.Namespace) -> bool:
    """Deploy a k3s node: switch, auto-reboot if needed, verify k8s health."""
    if not deploy_host(host, mode="switch"):
        return False

    if not handle_reboot(host, force_reboot=args.reboot, no_reboot=args.no_reboot,
                         force_reboot_prompt=False):
        return False

    if host.k8s_health_check:
        if not wait_for_node_healthy(host):
            return False

    print(f"  ✓ {host.hostname} successfully updated and healthy")
    return True


def deploy_standard(host: Host, args: argparse.Namespace) -> bool:
    """Deploy a standard host: switch, prompt-reboot if needed, optional k8s check."""
    if not deploy_host(host, mode="switch"):
        return False

    if not handle_reboot(host, force_reboot=args.reboot, no_reboot=args.no_reboot,
                         force_reboot_prompt=args.force_reboot):
        return False

    if host.k8s_health_check:
        if not wait_for_node_healthy(host):
            return False

    print(f"  ✓ {host.hostname} successfully updated")
    return True


def deploy_router_safe(host: Host, args: argparse.Namespace) -> bool:
    """Deploy the router safely: arm watchdog, test, verify, boot, disarm."""
    watchdog_timeout = args.router_watchdog_timeout

    # Step 1: Arm watchdog BEFORE any changes
    unit_name = arm_watchdog(host, watchdog_timeout)
    if unit_name is None:
        print(f"  FATAL: Cannot proceed without watchdog protection")
        return False

    # Step 2: Deploy with 'test' (activate but don't set as boot default)
    if not deploy_host(host, mode="test"):
        print(f"  'nixos-rebuild test' failed.")
        print(f"  Watchdog will reboot router in <={watchdog_timeout}s to restore old config")
        return False

    # Step 3: Wait for config to stabilize, then verify connectivity
    print(f"  Waiting {ROUTER_STABILIZE_WAIT}s for config to stabilize...")
    time.sleep(ROUTER_STABILIZE_WAIT)

    print(f"  Running connectivity checks...")
    if not verify_router_connectivity(host):
        print(f"  Connectivity checks FAILED after 'nixos-rebuild test'")
        print(f"  Watchdog will reboot router in <={watchdog_timeout}s to restore old config")
        return False

    # Step 4: Persist with 'boot'
    print(f"  Checks passed. Persisting config with 'boot'...")
    if not deploy_host(host, mode="boot"):
        print(f"  'nixos-rebuild boot' failed! Config is active but NOT persisted as boot default.")
        disarm_watchdog(host, unit_name)
        return False

    # Step 5: Disarm watchdog
    disarm_watchdog(host, unit_name)

    if needs_reboot(host):
        msg = f"{host.hostname} needs reboot for kernel/param changes (reboot manually)"
        print(f"  ⚠ {msg}")
        deploy_warnings.append(msg)

    print(f"  ✓ Router deploy succeeded and persisted")
    return True


STRATEGY_HANDLERS = {
    DeployStrategy.ROLLING_K3S: deploy_rolling_k3s,
    DeployStrategy.STANDARD: deploy_standard,
    DeployStrategy.ROUTER_SAFE: deploy_router_safe,
}


def process_host(host: Host, args: argparse.Namespace) -> bool:
    """Deploy a host using its configured strategy."""
    print(f"\n{'=' * 60}")
    print(f"Processing {host.hostname} (strategy={host.deploy_strategy.value}, "
          f"reboot={host.reboot_policy.value})")
    print(f"{'=' * 60}")

    if not check_ssh(host):
        return False

    if args.dry_run:
        return process_host_dry_run(host)

    handler = STRATEGY_HANDLERS[host.deploy_strategy]
    return handler(host, args)


def process_host_dry_run(host: Host) -> bool:
    """Dry-run: verify SSH (already done), k8s health, flake build, router prereqs."""
    print(f"  [DRY-RUN] Checking {host.hostname}...")

    if host.k8s_health_check:
        is_ready, status = get_node_status(host.hostname)
        if is_ready:
            print(f"  ✓ Node {host.hostname} is healthy (Ready)")
        else:
            print(f"  ✗ Node {host.hostname} is not healthy: {status}")
            return False

    if host.deploy_strategy == DeployStrategy.ROUTER_SAFE:
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

    if not build_flake(host):
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
        "--router-watchdog-timeout",
        type=int,
        default=300,
        help="Router watchdog timeout in seconds (default: 300)",
    )
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    # Validate mutually exclusive reboot options
    if args.reboot and args.no_reboot:
        print("Error: --reboot and --no-reboot cannot be used together")
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

    # Deploy
    failed_hosts = []
    for host in hosts:
        success = process_host(host, args)

        if not success:
            failed_hosts.append(host.hostname)

            if host.deploy_strategy == DeployStrategy.ROLLING_K3S:
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
