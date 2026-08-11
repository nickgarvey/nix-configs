{ config, lib, pkgs, ... }:

# UniFi Network Application controller (nspawn container, br-lan veth).
#
# CURRENTLY DISABLED and fully unwired. `homelab.unifi.enable = false` in
# hosts/dragonsreach/configuration.nix (mongodb fails to build on the current
# nixpkgs pin). The DNS record and the DHCP advertisement that pointed clients
# here were removed on 2026-08-10, because they were telling every AP and switch
# on the LAN to adopt against 10.28.0.4, where nothing had been listening.
#
# To bring it back, all four of these are required — the first three are what
# was removed, and the fourth is why it is off:
#
#   1. hosts/dragonsreach/configuration.nix — drop `homelab.unifi.enable = false`
#      (this module defaults to enabled).
#   2. modules/networking/dns.nix — restore the A record in `records`:
#          unifi = { v4 = [ "10.28.0.4" ]; v6 = []; };
#      Keep it v4-only; see the sysctl note at the bottom of this file.
#   3. modules/router/kea-dhcp.nix — restore the inform URL in subnet4's
#      `option-data` (DHCP option 43, suboption 01, encoding 10.28.0.4):
#          { name = "vendor-encapsulated-options"; data = "01:04:0a:1c:00:04"; csv-format = false; }
#      Devices already adopted keep their inform URL in their own config; this
#      option only matters for factory-reset or newly-added hardware.
#   4. Resolve the mongodb build. It broke on a cheetah3 metadata check under
#      python 3.14; a flake update that picks up the upstream fix should clear it.
#
# Steps 2 and 3 are only needed if you want adoption to work again — the
# controller itself runs fine without them.
#
# Switches and APs adopt over IPv4 — the container is IPv4-only on purpose.
#
# A previous deployment used host networking (privateNetwork = false) and
# interfered with the router: Unifi bound wildcard on every interface
# including WAN, shared the router's sysctls/conntrack, and required custom
# nftables rules on br-lan. This module uses bridge attachment so
# common.nix sets privateNetwork = true, confining Unifi's listeners to
# the container's own netns. See commit 1c0a3a2 for the prior teardown.

let
  cfg = config.homelab.unifi;
in
{
  imports = [ ./common.nix ];

  options.homelab.unifi.enable = lib.mkEnableOption "UniFi Network Application container" // {
    default = true;
  };

  config = lib.mkIf cfg.enable {
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
  };
}
