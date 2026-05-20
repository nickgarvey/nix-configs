{ config, lib, pkgs, ... }:

# UniFi Network Application controller (nspawn container, br-lan veth).
#
# Reachable as `unifi` / `unifi.home.arpa` (see modules/dns.nix) and also
# advertised via DHCP option 43 (see modules/router/kea-dhcp.nix). Switches
# and APs adopt over IPv4 — the container is IPv4-only on purpose.
#
# A previous deployment used host networking (privateNetwork = false) and
# interfered with the router: Unifi bound wildcard on every interface
# including WAN, shared the router's sysctls/conntrack, and required custom
# nftables rules on br-lan. This module uses bridge attachment so
# common.nix sets privateNetwork = true, confining Unifi's listeners to
# the container's own netns. See commit 1c0a3a2 for the prior teardown.

{
  imports = [ ./common.nix ];

  nspawn.network.unifi = {
    attachment = "bridge";
    hostBridge = "br-lan";
    localAddress = "10.28.0.4/16";
    ipv4Gateway = "10.28.0.1";
    ipv4Nameservers = [ "10.28.0.1" ];
    # Unifi reaches out to sso.ui.com during the first-run wizard.
    ipv4DefaultRoute = true;
  };

  # Unifi's Java/Mongo combo is thread-heavy; the default TasksMax
  # tripped the prior deployment after long uptime.
  systemd.services."container@unifi".serviceConfig.TasksMax = 65536;

  containers.unifi.config = { config, pkgs, lib, ... }: {
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [ "unifi-controller" "mongodb" ];

    services.unifi = {
      enable = true;
      openFirewall = false;
    };

    # Container picks up a SLAAC IPv6 from the LAN bridge but has no v6
    # default route (HE prefix reputation; see modules/router/lan-ipv6.nix).
    # glibc/JVM prefer AAAA when any global IPv6 is configured, so SSO
    # lookups for dual-stack hosts (sso.ui.com) black-hole. Disable IPv6
    # on eth0 inside the container — Unifi adoption is IPv4 anyway.
    boot.kernel.sysctl."net.ipv6.conf.eth0.disable_ipv6" = 1;
  };
}
