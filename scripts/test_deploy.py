#!/usr/bin/env python3
"""Unit tests for deploy.py — all logic that doesn't require remote access."""

import argparse
import subprocess
import unittest
from unittest.mock import MagicMock, call, patch

import deploy
from deploy import (
    ALL_HOSTS,
    Host,
    RebootPolicy,
    build_parser,
    deploy_safe,
    deploy_unsafe,
    deploy_warnings,
    dns_check,
    filter_hosts,
    handle_reboot,
    needs_reboot,
    ping_check,
    process_host,
    verify_host_connectivity,
)


class TestHostConfig(unittest.TestCase):
    def test_fqdn_with_domain(self):
        h = Host("k3s-node-1", "k3s-node-1", "home.arpa",
                 RebootPolicy.AUTO)
        self.assertEqual(h.fqdn, "k3s-node-1.home.arpa")

    def test_fqdn_without_domain(self):
        h = Host("framework", "framework", "",
                 RebootPolicy.PROMPT)
        self.assertEqual(h.fqdn, "framework")

    def test_fqdn_ssh_address_override(self):
        h = Host("router", "router", "home.arpa",
                 RebootPolicy.NEVER,
                 ssh_address="10.28.0.1")
        self.assertEqual(h.fqdn, "10.28.0.1")

    def test_deploy_order_sorting(self):
        hosts = list(ALL_HOSTS)
        hosts.sort(key=lambda h: h.deploy_order)
        names = [h.hostname for h in hosts]
        # k3s nodes first, then framework, microatx, router last
        self.assertEqual(names.index("k3s-node-1"), 0)
        self.assertEqual(names.index("k3s-node-3"), 2)
        self.assertEqual(names.index("framework"), 3)
        self.assertEqual(names.index("microatx"), 4)
        self.assertEqual(names.index("framework13-laptop"), 5)
        self.assertEqual(names.index("router"), 6)

    def test_all_hosts_have_unique_hostnames(self):
        names = [h.hostname for h in ALL_HOSTS]
        self.assertEqual(len(names), len(set(names)))

    def test_all_hosts_have_groups(self):
        for h in ALL_HOSTS:
            self.assertTrue(len(h.groups) > 0, f"{h.hostname} has no groups")

    def test_default_connectivity_checks(self):
        h = Host("test", "test", "home.arpa", RebootPolicy.AUTO)
        self.assertEqual(h.connectivity_checks, ["ssh", "ping_gateway"])

    def test_router_has_extended_checks(self):
        router = next(h for h in ALL_HOSTS if h.hostname == "router")
        self.assertIn("ping_internet", router.connectivity_checks)
        self.assertIn("dns", router.connectivity_checks)
        self.assertIn("ipv6_tunnel", router.connectivity_checks)

    def test_laptop_ssh_only(self):
        laptop = next(h for h in ALL_HOSTS if h.hostname == "framework13-laptop")
        self.assertEqual(laptop.connectivity_checks, ["ssh"])


class TestFilterHosts(unittest.TestCase):
    def test_no_filters_returns_default_sorted(self):
        result = filter_hosts(ALL_HOSTS, None, None)
        default_hosts = [h for h in ALL_HOSTS if h.default]
        self.assertEqual(len(result), len(default_hosts))
        for h in result:
            self.assertTrue(h.default)
        orders = [h.deploy_order for h in result]
        self.assertEqual(orders, sorted(orders))

    def test_no_filters_excludes_non_default(self):
        result = filter_hosts(ALL_HOSTS, None, None)
        names = [h.hostname for h in result]
        self.assertNotIn("framework13-laptop", names)

    def test_explicit_host_includes_non_default(self):
        result = filter_hosts(ALL_HOSTS, ["framework13-laptop"], None)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].hostname, "framework13-laptop")

    def test_filter_by_hostname(self):
        result = filter_hosts(ALL_HOSTS, ["router", "microatx"], None)
        names = [h.hostname for h in result]
        self.assertEqual(set(names), {"router", "microatx"})

    def test_filter_by_group(self):
        result = filter_hosts(ALL_HOSTS, None, ["k3s"])
        names = [h.hostname for h in result]
        self.assertIn("k3s-node-1", names)
        self.assertNotIn("framework", names)  # framework is no longer in k3s group
        self.assertNotIn("microatx", names)

    def test_filter_by_hostname_and_group(self):
        result = filter_hosts(ALL_HOSTS, ["k3s-node-1"], ["k3s"])
        names = [h.hostname for h in result]
        self.assertEqual(names, ["k3s-node-1"])

    def test_filter_no_match(self):
        result = filter_hosts(ALL_HOSTS, ["nonexistent"], None)
        self.assertEqual(result, [])

    def test_filter_router_group(self):
        result = filter_hosts(ALL_HOSTS, None, ["router"])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].hostname, "router")


class TestArgParsing(unittest.TestCase):
    def test_reboot_no_reboot_exclusive(self):
        """These are validated in main(), not argparse, but test the parser builds."""
        parser = build_parser()
        args = parser.parse_args(["--reboot", "--no-reboot"])
        self.assertTrue(args.reboot)
        self.assertTrue(args.no_reboot)

    def test_default_watchdog_timeout(self):
        parser = build_parser()
        args = parser.parse_args([])
        self.assertEqual(args.watchdog_timeout, 300)

    def test_custom_watchdog_timeout(self):
        parser = build_parser()
        args = parser.parse_args(["--watchdog-timeout", "600"])
        self.assertEqual(args.watchdog_timeout, 600)

    def test_no_safe_flag(self):
        parser = build_parser()
        args = parser.parse_args(["--no-safe"])
        self.assertTrue(args.no_safe)

    def test_no_safe_default_false(self):
        parser = build_parser()
        args = parser.parse_args([])
        self.assertFalse(args.no_safe)

    def test_skip_k8s_check_flag(self):
        parser = build_parser()
        args = parser.parse_args(["--skip-k8s-check"])
        self.assertTrue(args.skip_k8s_check)

    def test_skip_k8s_check_default_false(self):
        parser = build_parser()
        args = parser.parse_args([])
        self.assertFalse(args.skip_k8s_check)

    def test_group_flag(self):
        parser = build_parser()
        args = parser.parse_args(["--group", "k3s", "infra"])
        self.assertEqual(args.group, ["k3s", "infra"])

    def test_hosts_flag(self):
        parser = build_parser()
        args = parser.parse_args(["--hosts", "router"])
        self.assertEqual(args.hosts, ["router"])


class TestHandleReboot(unittest.TestCase):
    def setUp(self):
        deploy.deploy_warnings.clear()

    def _make_host(self, policy: RebootPolicy) -> Host:
        return Host("test", "test", "home.arpa", policy)

    @patch("deploy.reboot_host", return_value=True)
    @patch("deploy.needs_reboot", return_value=True)
    def test_auto_reboots_without_prompt(self, mock_needs, mock_reboot):
        h = self._make_host(RebootPolicy.AUTO)
        result = handle_reboot(h, force_reboot=False, no_reboot=False,
                               force_reboot_prompt=False)
        self.assertTrue(result)
        mock_reboot.assert_called_once_with(h)

    @patch("deploy.reboot_host")
    @patch("deploy.needs_reboot", return_value=True)
    def test_no_reboot_flag_skips(self, mock_needs, mock_reboot):
        h = self._make_host(RebootPolicy.AUTO)
        result = handle_reboot(h, force_reboot=False, no_reboot=True,
                               force_reboot_prompt=False)
        self.assertTrue(result)
        mock_reboot.assert_not_called()
        self.assertEqual(len(deploy.deploy_warnings), 1)
        self.assertIn("--no-reboot", deploy.deploy_warnings[0])

    @patch("deploy.reboot_host", return_value=True)
    @patch("deploy.needs_reboot", return_value=False)
    def test_force_reboot_flag(self, mock_needs, mock_reboot):
        h = self._make_host(RebootPolicy.PROMPT)
        result = handle_reboot(h, force_reboot=True, no_reboot=False,
                               force_reboot_prompt=False)
        self.assertTrue(result)
        mock_reboot.assert_called_once()

    @patch("builtins.input", return_value="y")
    @patch("deploy.reboot_host", return_value=True)
    @patch("deploy.needs_reboot", return_value=True)
    def test_prompt_policy_asks_user_yes(self, mock_needs, mock_reboot, mock_input):
        h = self._make_host(RebootPolicy.PROMPT)
        result = handle_reboot(h, force_reboot=False, no_reboot=False,
                               force_reboot_prompt=False)
        self.assertTrue(result)
        mock_input.assert_called_once()
        mock_reboot.assert_called_once()

    @patch("builtins.input", return_value="n")
    @patch("deploy.reboot_host")
    @patch("deploy.needs_reboot", return_value=True)
    def test_prompt_policy_asks_user_no(self, mock_needs, mock_reboot, mock_input):
        h = self._make_host(RebootPolicy.PROMPT)
        result = handle_reboot(h, force_reboot=False, no_reboot=False,
                               force_reboot_prompt=False)
        self.assertTrue(result)
        mock_reboot.assert_not_called()
        self.assertEqual(len(deploy.deploy_warnings), 1)
        self.assertIn("declined", deploy.deploy_warnings[0])

    @patch("deploy.reboot_host", return_value=True)
    @patch("deploy.needs_reboot", return_value=True)
    def test_force_reboot_prompt_skips_prompt(self, mock_needs, mock_reboot):
        h = self._make_host(RebootPolicy.PROMPT)
        result = handle_reboot(h, force_reboot=False, no_reboot=False,
                               force_reboot_prompt=True)
        self.assertTrue(result)
        mock_reboot.assert_called_once()

    @patch("deploy.reboot_host")
    @patch("deploy.needs_reboot", return_value=True)
    def test_never_policy_skips(self, mock_needs, mock_reboot):
        h = self._make_host(RebootPolicy.NEVER)
        result = handle_reboot(h, force_reboot=False, no_reboot=False,
                               force_reboot_prompt=False)
        self.assertTrue(result)
        mock_reboot.assert_not_called()
        self.assertEqual(len(deploy.deploy_warnings), 1)
        self.assertIn("NEVER", deploy.deploy_warnings[0])


class TestProcessHostDispatch(unittest.TestCase):
    @patch("deploy.deploy_safe", return_value=True)
    @patch("deploy.check_ssh", return_value=True)
    def test_safe_mode_by_default(self, mock_ssh, mock_safe):
        h = Host("test", "test", "home.arpa", RebootPolicy.AUTO)
        args = build_parser().parse_args([])
        process_host(h, args)
        mock_safe.assert_called_once()

    @patch("deploy.deploy_unsafe", return_value=True)
    @patch("deploy.check_ssh", return_value=True)
    def test_no_safe_uses_unsafe(self, mock_ssh, mock_unsafe):
        h = Host("test", "test", "home.arpa", RebootPolicy.AUTO)
        args = build_parser().parse_args(["--no-safe"])
        process_host(h, args)
        mock_unsafe.assert_called_once()

    @patch("deploy.check_ssh", return_value=False)
    def test_ssh_failure_stops(self, mock_ssh):
        h = Host("test", "test", "", RebootPolicy.PROMPT)
        args = build_parser().parse_args([])
        result = process_host(h, args)
        self.assertFalse(result)


class TestNeedsReboot(unittest.TestCase):
    def _make_host(self):
        return Host("test", "test", "home.arpa", RebootPolicy.AUTO)

    @patch("deploy.get_new_kernel_params", return_value={"a", "b"})
    @patch("deploy.get_booted_kernel_params", return_value={"a", "b"})
    @patch("deploy.get_new_kernel", return_value="6.1.0")
    @patch("deploy.get_running_kernel", return_value="6.1.0")
    def test_no_reboot_same_kernel_same_params(self, *_):
        self.assertFalse(needs_reboot(self._make_host()))

    @patch("deploy.get_new_kernel_params", return_value={"a", "b"})
    @patch("deploy.get_booted_kernel_params", return_value={"a", "b"})
    @patch("deploy.get_new_kernel", return_value="6.2.0")
    @patch("deploy.get_running_kernel", return_value="6.1.0")
    def test_reboot_kernel_changed(self, *_):
        self.assertTrue(needs_reboot(self._make_host()))

    @patch("deploy.get_new_kernel_params", return_value={"a", "b", "c"})
    @patch("deploy.get_booted_kernel_params", return_value={"a", "b"})
    @patch("deploy.get_new_kernel", return_value="6.1.0")
    @patch("deploy.get_running_kernel", return_value="6.1.0")
    def test_reboot_params_changed(self, *_):
        self.assertTrue(needs_reboot(self._make_host()))

    @patch("deploy.get_new_kernel_params", return_value=None)
    @patch("deploy.get_booted_kernel_params", return_value=None)
    @patch("deploy.get_new_kernel", return_value=None)
    @patch("deploy.get_running_kernel", return_value=None)
    def test_no_reboot_when_checks_fail(self, *_):
        self.assertFalse(needs_reboot(self._make_host()))


class TestSafeDeploy(unittest.TestCase):
    def setUp(self):
        deploy.deploy_warnings.clear()

    def _make_host(self, **kwargs):
        defaults = dict(hostname="test", flake_name="test", domain="home.arpa",
                        reboot_policy=RebootPolicy.AUTO)
        defaults.update(kwargs)
        return Host(**defaults)

    def _make_args(self, timeout=300):
        return build_parser().parse_args(["--watchdog-timeout", str(timeout)])

    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])  # test, boot
    @patch("deploy.verify_config_active", return_value=True)
    @patch("deploy.verify_host_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_success_flow(self, mock_build, mock_clear, mock_arm, mock_verify_conn, mock_verify_cfg, mock_deploy, mock_disarm, mock_reboot):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertTrue(result)
        mock_build.assert_called_once_with(h)
        mock_arm.assert_called_once_with(h, 300)
        self.assertEqual(mock_deploy.call_count, 2)
        mock_deploy.assert_any_call(h, mode="test", timeout=60)
        mock_deploy.assert_any_call(h, mode="boot", timeout=60)
        mock_disarm.assert_called_once_with(h, "deploy-watchdog-123")

    @patch("deploy.arm_watchdog", return_value=None)
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_watchdog_arm_failure_aborts(self, mock_build, mock_clear, mock_arm):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)

    @patch("deploy.build_host", return_value=None)
    def test_build_failure_aborts(self, mock_build):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", return_value=False)  # test fails
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_test_failure_no_disarm(self, mock_build, mock_clear, mock_arm, mock_deploy, mock_disarm):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)
        mock_disarm.assert_not_called()

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, False])  # test ok, boot fails
    @patch("deploy.verify_config_active", return_value=True)
    @patch("deploy.verify_host_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_boot_failure_still_disarms(self, mock_build, mock_clear, mock_arm, mock_verify_conn,
                                        mock_verify_cfg, mock_deploy, mock_disarm):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)
        mock_disarm.assert_called_once()

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", return_value=True)
    @patch("deploy.verify_host_connectivity", return_value=False)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_connectivity_failure_no_disarm(self, mock_build, mock_clear, mock_arm, mock_verify,
                                            mock_deploy, mock_disarm):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)
        mock_disarm.assert_not_called()

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", return_value=True)
    @patch("deploy.verify_config_active", return_value=False)
    @patch("deploy.verify_host_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_config_mismatch_no_boot(self, mock_build, mock_clear, mock_arm, mock_verify_conn,
                                      mock_verify_cfg, mock_deploy, mock_disarm):
        h = self._make_host()
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)
        # Should not have called boot (deploy_host only called once for test)
        mock_deploy.assert_called_once()
        mock_disarm.assert_not_called()

    @patch("deploy.wait_for_node_healthy", return_value=True)
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])
    @patch("deploy.verify_config_active", return_value=True)
    @patch("deploy.verify_host_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_k8s_health_check_runs(self, mock_build, mock_clear, mock_arm, mock_verify_conn, mock_verify_cfg,
                                    mock_deploy, mock_disarm, mock_reboot, mock_health):
        h = self._make_host(k8s_health_check=True)
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertTrue(result)
        mock_health.assert_called_once()

    @patch("deploy.wait_for_node_healthy", return_value=False)
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])
    @patch("deploy.verify_config_active", return_value=True)
    @patch("deploy.verify_host_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_k8s_health_failure(self, mock_build, mock_clear, mock_arm, mock_verify_conn, mock_verify_cfg,
                                 mock_deploy, mock_disarm, mock_reboot, mock_health):
        h = self._make_host(k8s_health_check=True)
        args = self._make_args()
        result = deploy_safe(h, args)
        self.assertFalse(result)

    @patch("deploy.wait_for_node_healthy")
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])
    @patch("deploy.verify_config_active", return_value=True)
    @patch("deploy.verify_host_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.clear_nixos_rebuild_unit")
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_skip_k8s_check_skips_health(self, mock_build, mock_clear, mock_arm, mock_verify_conn, mock_verify_cfg,
                                          mock_deploy, mock_disarm, mock_reboot, mock_health):
        h = self._make_host(k8s_health_check=True)
        args = build_parser().parse_args(["--skip-k8s-check"])
        result = deploy_safe(h, args)
        self.assertTrue(result)
        mock_health.assert_not_called()


class TestUnsafeDeploy(unittest.TestCase):
    def _make_host(self, **kwargs):
        defaults = dict(hostname="test", flake_name="test", domain="home.arpa",
                        reboot_policy=RebootPolicy.AUTO)
        defaults.update(kwargs)
        return Host(**defaults)

    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_success_uses_switch(self, mock_build, mock_deploy, mock_reboot):
        h = self._make_host()
        args = build_parser().parse_args(["--no-safe"])
        result = deploy_unsafe(h, args)
        self.assertTrue(result)
        mock_build.assert_called_once_with(h)
        mock_deploy.assert_called_once_with(h, mode="switch", timeout=60)

    @patch("deploy.build_host", return_value=False)
    def test_build_failure(self, mock_build):
        h = self._make_host()
        args = build_parser().parse_args(["--no-safe"])
        result = deploy_unsafe(h, args)
        self.assertFalse(result)

    @patch("deploy.deploy_host", return_value=False)
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_deploy_failure(self, mock_build, mock_deploy):
        h = self._make_host()
        args = build_parser().parse_args(["--no-safe"])
        result = deploy_unsafe(h, args)
        self.assertFalse(result)

    @patch("deploy.wait_for_node_healthy", return_value=True)
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_with_k8s_check(self, mock_build, mock_deploy, mock_reboot, mock_health):
        h = self._make_host(k8s_health_check=True)
        args = build_parser().parse_args(["--no-safe"])
        result = deploy_unsafe(h, args)
        self.assertTrue(result)
        mock_health.assert_called_once()

    @patch("deploy.wait_for_node_healthy")
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    @patch("deploy.build_host", return_value="/nix/store/fake-system-path")
    def test_skip_k8s_check(self, mock_build, mock_deploy, mock_reboot, mock_health):
        h = self._make_host(k8s_health_check=True)
        args = build_parser().parse_args(["--no-safe", "--skip-k8s-check"])
        result = deploy_unsafe(h, args)
        self.assertTrue(result)
        mock_health.assert_not_called()


class TestConnectivityChecks(unittest.TestCase):
    @patch("deploy.run_cmd")
    def test_ping_check_success(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(ping_check("1.1.1.1"))

    @patch("deploy.run_cmd")
    def test_ping_check_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1)
        self.assertFalse(ping_check("1.1.1.1"))

    @patch("deploy.run_cmd", side_effect=subprocess.TimeoutExpired(cmd="ping", timeout=20))
    def test_ping_check_timeout(self, mock_run):
        self.assertFalse(ping_check("1.1.1.1"))

    @patch("deploy.run_cmd")
    def test_ping_check_via_host(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(ping_check("10.28.0.1", via_host="k3s-node-1.home.arpa"))
        cmd = mock_run.call_args[0][0]
        self.assertIn("ssh", cmd)
        self.assertIn("k3s-node-1.home.arpa", cmd)

    @patch("deploy.run_cmd")
    def test_dns_check_success(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(dns_check())

    @patch("deploy.run_cmd")
    def test_dns_check_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=2)
        self.assertFalse(dns_check())

    @patch("deploy.time")
    @patch("deploy.check_ssh", return_value=True)
    @patch("deploy.ping_check", return_value=True)
    def test_verify_default_checks_pass(self, mock_ping, mock_ssh, mock_time):
        h = Host("test", "test", "home.arpa", RebootPolicy.AUTO)
        self.assertTrue(verify_host_connectivity(h))

    @patch("deploy.time")
    @patch("deploy.check_ssh", return_value=True)
    @patch("deploy.ping_check", return_value=False)
    def test_verify_gateway_ping_fails_retries(self, mock_ping, mock_ssh, mock_time):
        h = Host("test", "test", "home.arpa", RebootPolicy.AUTO)
        self.assertFalse(verify_host_connectivity(h))
        # Should have retried VERIFY_RETRIES times
        self.assertEqual(mock_ssh.call_count, deploy.VERIFY_RETRIES)

    @patch("deploy.ping6_check", return_value=True)
    @patch("deploy.dns_check", return_value=True)
    @patch("deploy.ping_check", return_value=True)
    @patch("deploy.check_ssh", return_value=True)
    def test_verify_router_all_pass(self, mock_ssh, mock_ping, mock_dns, mock_ping6):
        h = Host("router", "router", "", RebootPolicy.NEVER,
                 ssh_address="10.28.0.1",
                 connectivity_checks=["ssh", "ping_internet", "dns", "ipv6_tunnel", "ipv6_internet"])
        self.assertTrue(verify_host_connectivity(h))

    @patch("deploy.time")
    @patch("deploy.ping6_check", return_value=True)
    @patch("deploy.dns_check", return_value=True)
    @patch("deploy.ping_check", return_value=False)
    @patch("deploy.check_ssh", return_value=True)
    def test_verify_router_ping_fails(self, mock_ssh, mock_ping, mock_dns, mock_ping6, mock_time):
        h = Host("router", "router", "", RebootPolicy.NEVER,
                 ssh_address="10.28.0.1",
                 connectivity_checks=["ssh", "ping_internet", "dns", "ipv6_tunnel", "ipv6_internet"])
        self.assertFalse(verify_host_connectivity(h))


if __name__ == "__main__":
    unittest.main()
