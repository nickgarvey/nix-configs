#!/usr/bin/env python3
"""
Deploy NixOS updates to k3s nodes with verification and automatic reboots.

This script:
1. Pushes updates to each host using nixos-rebuild
2. Verifies the update succeeded
3. Reboots if a kernel update occurred
4. Waits for the host to come back online
5. Verifies the node is healthy in kubernetes
6. Only then proceeds to the next host

Dry-run mode:
- Confirms SSH works
- Verifies node is healthy
- Compiles the flake for each host (without deploying)
"""

import argparse
import subprocess
import sys
import time
from dataclasses import dataclass

# Host configurations
# Each tuple is (hostname, flake_name, domain_suffix)
HOSTS = [
    ("k3s-node-1", "k3s-node-1", "home.arpa"),
    ("k3s-node-2", "k3s-node-2", "home.arpa"),
    ("k3s-node-3", "k3s-node-3", "home.arpa"),
    ("framework", "framework", "home.arpa"),
]

# Timeouts and retry configuration
SSH_TIMEOUT = 10
REBOOT_WAIT_INITIAL = 30  # seconds to wait before first check after reboot
REBOOT_WAIT_INTERVAL = 10  # seconds between checks
REBOOT_WAIT_MAX = 300  # maximum seconds to wait for host to come back
NODE_HEALTH_RETRIES = 12  # number of times to check node health
NODE_HEALTH_INTERVAL = 10  # seconds between health checks


@dataclass
class Host:
    hostname: str
    flake_name: str
    domain: str

    @property
    def fqdn(self) -> str:
        return f"{self.hostname}.{self.domain}"


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
    """Get the currently running kernel version on a host."""
    try:
        result = ssh_cmd(host, "uname -r")
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def get_booted_system(host: Host) -> str | None:
    """Get the system that was booted (to compare with current system)."""
    try:
        result = ssh_cmd(host, "readlink /run/booted-system")
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def get_current_system(host: Host) -> str | None:
    """Get the currently active system configuration."""
    try:
        result = ssh_cmd(host, "readlink /run/current-system")
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def get_new_kernel(host: Host) -> str | None:
    """Get the kernel version that will be used after reboot."""
    try:
        result = ssh_cmd(host, "ls /run/current-system/kernel-modules/lib/modules/")
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


def needs_reboot(host: Host) -> bool:
    """Check if a host needs a reboot (kernel version changed)."""
    running_kernel = get_running_kernel(host)
    new_kernel = get_new_kernel(host)
    if running_kernel and new_kernel:
        needs = running_kernel != new_kernel
        if needs:
            print(f"  Reboot needed: running kernel={running_kernel} != new kernel={new_kernel}")
        return needs
    return False


def get_node_status(hostname: str) -> tuple[bool, str]:
    """
    Check if a kubernetes node is ready.
    Returns (is_ready, status_string).
    """
    try:
        result = run_cmd(
            ["kubectl", "get", "node", hostname, "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"],
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
        # Use nohup and background to avoid SSH hanging
        run_cmd(
            ["ssh", "-o", f"ConnectTimeout={SSH_TIMEOUT}", host.fqdn,
             "sudo systemctl reboot"],
            check=False,  # Reboot will kill the SSH connection
            capture_output=True,
        )
    except subprocess.TimeoutExpired:
        pass  # Expected - connection drops during reboot

    return wait_for_host_online(host)


def deploy_host(host: Host) -> bool:
    """Deploy NixOS configuration to a host."""
    print(f"  Deploying to {host.fqdn}...")
    try:
        run_cmd([
            "nixos-rebuild", "switch",
            "--target-host", host.fqdn,
            "--flake", f".#{host.flake_name}",
            "--no-reexec",
            "--build-host", host.fqdn,
            "--sudo",
        ])
        print(f"  ✓ Deployment to {host.fqdn} succeeded")
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ✗ Deployment to {host.fqdn} failed: {e}")
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


def process_host_dry_run(host: Host) -> bool:
    """Process a host in dry-run mode."""
    print(f"\n{'=' * 60}")
    print(f"[DRY-RUN] Processing {host.hostname}")
    print(f"{'=' * 60}")

    # Check SSH
    if not check_ssh(host):
        return False

    # Check node health
    is_ready, status = get_node_status(host.hostname)
    if is_ready:
        print(f"  ✓ Node {host.hostname} is healthy (Ready)")
    else:
        print(f"  ✗ Node {host.hostname} is not healthy: {status}")
        return False

    # Build flake
    if not build_flake(host):
        return False

    print(f"  ✓ [DRY-RUN] {host.hostname} passed all checks")
    return True


def process_host(host: Host) -> bool:
    """Process a host: deploy, verify, reboot if needed, verify health."""
    print(f"\n{'=' * 60}")
    print(f"Processing {host.hostname}")
    print(f"{'=' * 60}")

    # Check SSH first
    if not check_ssh(host):
        return False

    # Deploy
    if not deploy_host(host):
        return False

    # Check if reboot is needed
    if needs_reboot(host):
        print(f"  Host {host.hostname} needs reboot for kernel/system update")
        if not reboot_host(host):
            return False
    else:
        print(f"  No reboot needed for {host.hostname}")

    # Wait for node to be healthy in kubernetes
    if not wait_for_node_healthy(host):
        return False

    print(f"  ✓ {host.hostname} successfully updated and healthy")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Deploy NixOS updates to k3s nodes",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Don't deploy or reboot; just verify SSH, node health, and flake builds",
    )
    parser.add_argument(
        "--hosts",
        nargs="+",
        metavar="HOSTNAME",
        help="Only process specific hosts (by hostname, not FQDN)",
    )
    args = parser.parse_args()

    # Build host list
    hosts = [Host(h[0], h[1], h[2]) for h in HOSTS]

    # Filter hosts if specified
    if args.hosts:
        hosts = [h for h in hosts if h.hostname in args.hosts]
        if not hosts:
            print(f"Error: No matching hosts found for: {args.hosts}")
            print(f"Available hosts: {[h[0] for h in HOSTS]}")
            sys.exit(1)

    print(f"Processing {len(hosts)} host(s): {[h.hostname for h in hosts]}")
    if args.dry_run:
        print("Mode: DRY-RUN (no changes will be made)")
    else:
        print("Mode: DEPLOY")

    failed_hosts = []
    for host in hosts:
        if args.dry_run:
            success = process_host_dry_run(host)
        else:
            success = process_host(host)

        if not success:
            failed_hosts.append(host.hostname)
            print(f"\n✗ Failed to process {host.hostname}, stopping.")
            break

    print(f"\n{'=' * 60}")
    print("Summary")
    print(f"{'=' * 60}")

    if failed_hosts:
        print(f"Failed hosts: {failed_hosts}")
        sys.exit(1)
    else:
        print("All hosts processed successfully!")
        sys.exit(0)


if __name__ == "__main__":
    main()
