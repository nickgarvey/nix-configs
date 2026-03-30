#!/usr/bin/env python3
"""Unit tests for deploy.py — all logic that doesn't require remote access."""

import argparse
import subprocess
import unittest
from unittest.mock import MagicMock, call, patch

import deploy
from deploy import (
    ALL_HOSTS,
    DeployStrategy,
    Host,
    RebootPolicy,
    build_parser,
    deploy_rolling_k3s,
    deploy_router_safe,
    deploy_standard,
    deploy_warnings,
    dns_check,
    filter_hosts,
    handle_reboot,
    needs_reboot,
    ping_check,
    process_host,
    verify_router_connectivity,
)


class TestHostConfig(unittest.TestCase):
    def test_fqdn_with_domain(self):
        h = Host("k3s-node-1", "k3s-node-1", "home.arpa",
                 DeployStrategy.ROLLING_K3S, RebootPolicy.AUTO)
        self.assertEqual(h.fqdn, "k3s-node-1.home.arpa")

    def test_fqdn_without_domain(self):
        h = Host("framework", "framework", "",
                 DeployStrategy.STANDARD, RebootPolicy.PROMPT)
        self.assertEqual(h.fqdn, "framework")

    def test_fqdn_ssh_address_override(self):
        h = Host("router", "router", "home.arpa",
                 DeployStrategy.ROUTER_SAFE, RebootPolicy.NEVER,
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
        self.assertEqual(names.index("router"), 5)

    def test_all_hosts_have_unique_hostnames(self):
        names = [h.hostname for h in ALL_HOSTS]
        self.assertEqual(len(names), len(set(names)))

    def test_all_hosts_have_groups(self):
        for h in ALL_HOSTS:
            self.assertTrue(len(h.groups) > 0, f"{h.hostname} has no groups")


class TestFilterHosts(unittest.TestCase):
    def test_no_filters_returns_all_sorted(self):
        result = filter_hosts(ALL_HOSTS, None, None)
        self.assertEqual(len(result), len(ALL_HOSTS))
        orders = [h.deploy_order for h in result]
        self.assertEqual(orders, sorted(orders))

    def test_filter_by_hostname(self):
        result = filter_hosts(ALL_HOSTS, ["router", "microatx"], None)
        names = [h.hostname for h in result]
        self.assertEqual(set(names), {"router", "microatx"})

    def test_filter_by_group(self):
        result = filter_hosts(ALL_HOSTS, None, ["k3s"])
        names = [h.hostname for h in result]
        self.assertIn("k3s-node-1", names)
        self.assertIn("framework", names)  # framework is in k3s group
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
        self.assertEqual(args.router_watchdog_timeout, 300)

    def test_custom_watchdog_timeout(self):
        parser = build_parser()
        args = parser.parse_args(["--router-watchdog-timeout", "600"])
        self.assertEqual(args.router_watchdog_timeout, 600)

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
        return Host("test", "test", "home.arpa",
                    DeployStrategy.STANDARD, policy)

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


class TestStrategyDispatch(unittest.TestCase):
    @patch("deploy.check_ssh", return_value=True)
    def test_rolling_k3s_dispatched(self, mock_ssh):
        mock_handler = MagicMock(return_value=True)
        h = Host("k3s-node-1", "k3s-node-1", "home.arpa",
                 DeployStrategy.ROLLING_K3S, RebootPolicy.AUTO,
                 k8s_health_check=True)
        args = build_parser().parse_args([])
        with patch.dict("deploy.STRATEGY_HANDLERS",
                        {DeployStrategy.ROLLING_K3S: mock_handler}):
            process_host(h, args)
        mock_handler.assert_called_once()

    @patch("deploy.check_ssh", return_value=True)
    def test_standard_dispatched(self, mock_ssh):
        mock_handler = MagicMock(return_value=True)
        h = Host("microatx", "microatx", "home.arpa",
                 DeployStrategy.STANDARD, RebootPolicy.PROMPT)
        args = build_parser().parse_args([])
        with patch.dict("deploy.STRATEGY_HANDLERS",
                        {DeployStrategy.STANDARD: mock_handler}):
            process_host(h, args)
        mock_handler.assert_called_once()

    @patch("deploy.check_ssh", return_value=True)
    def test_router_safe_dispatched(self, mock_ssh):
        mock_handler = MagicMock(return_value=True)
        h = Host("router", "router", "",
                 DeployStrategy.ROUTER_SAFE, RebootPolicy.NEVER,
                 ssh_address="10.28.0.1")
        args = build_parser().parse_args([])
        with patch.dict("deploy.STRATEGY_HANDLERS",
                        {DeployStrategy.ROUTER_SAFE: mock_handler}):
            process_host(h, args)
        mock_handler.assert_called_once()

    @patch("deploy.check_ssh", return_value=False)
    def test_ssh_failure_stops(self, mock_ssh):
        h = Host("test", "test", "",
                 DeployStrategy.STANDARD, RebootPolicy.PROMPT)
        args = build_parser().parse_args([])
        result = process_host(h, args)
        self.assertFalse(result)


class TestNeedsReboot(unittest.TestCase):
    def _make_host(self):
        return Host("test", "test", "home.arpa",
                    DeployStrategy.STANDARD, RebootPolicy.AUTO)

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


class TestRouterSafeDeploy(unittest.TestCase):
    def setUp(self):
        deploy.deploy_warnings.clear()

    def _make_router(self):
        return Host("router", "router", "",
                    DeployStrategy.ROUTER_SAFE, RebootPolicy.NEVER,
                    ssh_address="10.28.0.1")

    def _make_args(self, timeout=300):
        return build_parser().parse_args(["--router-watchdog-timeout", str(timeout)])

    @patch("deploy.needs_reboot", return_value=False)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])  # test, boot
    @patch("deploy.verify_router_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.time")
    def test_success_flow(self, mock_time, mock_arm, mock_verify, mock_deploy, mock_disarm, mock_needs):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertTrue(result)
        mock_arm.assert_called_once_with(h, 300)
        self.assertEqual(mock_deploy.call_count, 2)
        mock_deploy.assert_any_call(h, mode="test")
        mock_deploy.assert_any_call(h, mode="boot")
        mock_disarm.assert_called_once_with(h, "deploy-watchdog-123")

    @patch("deploy.arm_watchdog", return_value=None)
    def test_watchdog_arm_failure_aborts(self, mock_arm):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertFalse(result)

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", return_value=False)  # test fails
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    def test_test_failure_no_disarm(self, mock_arm, mock_deploy, mock_disarm):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertFalse(result)
        mock_disarm.assert_not_called()

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, False])  # test ok, boot fails
    @patch("deploy.verify_router_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.time")
    def test_boot_failure_still_disarms(self, mock_time, mock_arm, mock_verify,
                                        mock_deploy, mock_disarm):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertFalse(result)
        mock_disarm.assert_called_once()

    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", return_value=True)
    @patch("deploy.verify_router_connectivity", return_value=False)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.time")
    def test_connectivity_failure_no_disarm(self, mock_time, mock_arm, mock_verify,
                                            mock_deploy, mock_disarm):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertFalse(result)
        mock_disarm.assert_not_called()

    @patch("deploy.needs_reboot", return_value=True)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])
    @patch("deploy.verify_router_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.time")
    def test_kernel_update_warns_no_reboot(self, mock_time, mock_arm, mock_verify,
                                           mock_deploy, mock_disarm, mock_needs):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertTrue(result)
        self.assertEqual(len(deploy.deploy_warnings), 1)
        self.assertIn("reboot", deploy.deploy_warnings[0].lower())

    @patch("deploy.needs_reboot", return_value=False)
    @patch("deploy.disarm_watchdog")
    @patch("deploy.deploy_host", side_effect=[True, True])
    @patch("deploy.verify_router_connectivity", return_value=True)
    @patch("deploy.arm_watchdog", return_value="deploy-watchdog-123")
    @patch("deploy.time")
    def test_no_kernel_update_no_warning(self, mock_time, mock_arm, mock_verify,
                                         mock_deploy, mock_disarm, mock_needs):
        h = self._make_router()
        args = self._make_args()
        result = deploy_router_safe(h, args)
        self.assertTrue(result)
        self.assertEqual(len(deploy.deploy_warnings), 0)


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
    def test_dns_check_success(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(dns_check())

    @patch("deploy.run_cmd")
    def test_dns_check_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=2)
        self.assertFalse(dns_check())

    @patch("deploy.dns_check", return_value=True)
    @patch("deploy.ping_check", return_value=True)
    @patch("deploy.check_ssh", return_value=True)
    def test_verify_router_all_pass(self, mock_ssh, mock_ping, mock_dns):
        h = Host("router", "router", "", DeployStrategy.ROUTER_SAFE,
                 RebootPolicy.NEVER, ssh_address="10.28.0.1")
        self.assertTrue(verify_router_connectivity(h))

    @patch("deploy.dns_check", return_value=True)
    @patch("deploy.ping_check", return_value=False)
    @patch("deploy.check_ssh", return_value=True)
    def test_verify_router_ping_fails(self, mock_ssh, mock_ping, mock_dns):
        h = Host("router", "router", "", DeployStrategy.ROUTER_SAFE,
                 RebootPolicy.NEVER, ssh_address="10.28.0.1")
        self.assertFalse(verify_router_connectivity(h))


class TestRollingK3s(unittest.TestCase):
    def _make_k3s_host(self):
        return Host("k3s-node-1", "k3s-node-1", "home.arpa",
                    DeployStrategy.ROLLING_K3S, RebootPolicy.AUTO,
                    k8s_health_check=True)

    @patch("deploy.wait_for_node_healthy", return_value=True)
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    def test_success(self, mock_deploy, mock_reboot, mock_health):
        h = self._make_k3s_host()
        args = build_parser().parse_args([])
        self.assertTrue(deploy_rolling_k3s(h, args))
        mock_deploy.assert_called_once_with(h, mode="switch")
        mock_health.assert_called_once()

    @patch("deploy.handle_reboot")
    @patch("deploy.deploy_host", return_value=False)
    def test_deploy_failure(self, mock_deploy, mock_reboot):
        h = self._make_k3s_host()
        args = build_parser().parse_args([])
        self.assertFalse(deploy_rolling_k3s(h, args))
        mock_reboot.assert_not_called()

    @patch("deploy.wait_for_node_healthy", return_value=False)
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    def test_health_check_failure(self, mock_deploy, mock_reboot, mock_health):
        h = self._make_k3s_host()
        args = build_parser().parse_args([])
        self.assertFalse(deploy_rolling_k3s(h, args))


class TestStandard(unittest.TestCase):
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    def test_no_k8s_check(self, mock_deploy, mock_reboot):
        h = Host("microatx", "microatx", "home.arpa",
                 DeployStrategy.STANDARD, RebootPolicy.PROMPT,
                 k8s_health_check=False)
        args = build_parser().parse_args([])
        self.assertTrue(deploy_standard(h, args))

    @patch("deploy.wait_for_node_healthy", return_value=True)
    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    def test_with_k8s_check(self, mock_deploy, mock_reboot, mock_health):
        h = Host("framework", "framework", "",
                 DeployStrategy.STANDARD, RebootPolicy.PROMPT,
                 k8s_health_check=True)
        args = build_parser().parse_args([])
        self.assertTrue(deploy_standard(h, args))
        mock_health.assert_called_once()

    @patch("deploy.handle_reboot", return_value=True)
    @patch("deploy.deploy_host", return_value=True)
    def test_force_reboot_passed(self, mock_deploy, mock_reboot):
        h = Host("microatx", "microatx", "home.arpa",
                 DeployStrategy.STANDARD, RebootPolicy.PROMPT)
        args = build_parser().parse_args(["--force-reboot"])
        deploy_standard(h, args)
        mock_reboot.assert_called_once_with(
            h, force_reboot=False, no_reboot=False, force_reboot_prompt=True)


if __name__ == "__main__":
    unittest.main()
