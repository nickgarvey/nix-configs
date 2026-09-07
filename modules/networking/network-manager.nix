{ config, lib, ... }:

# Pure-NetworkManager workstation networking. Hosts import this to get NM as the
# network backend (wired + wifi managed interactively, network applet, DHCP UX).
#
# Wifi is joined interactively (nmcli/GUI applet) and persisted by NM across
# reboots — there is no declarative credential profile here.
#
# Hosts that have a static LAN identity in lan-hosts.nix get a MAC-bound wired
# profile that pins their static IPv6 and MAC-keyed DHCP, so their published
# AAAA and DHCP reservation stay valid. Cluster routes (pods/LB/delegated /64s)
# are learned from the router's RFC 4191 2001:470:482f::/48 route-info RA — see
# modules/router/lan-ipv6.nix — so none are configured here. Wifi-only hosts
# (e.g. dovahkiin) carry a lan-hosts entry with ipv6 = null: the MAC-keyed
# DHCPv4 reservation and its A record still apply over wifi, but there is no
# ethernet NIC for the wired profile to attach to, so a static AAAA would name
# an address the host never configures.

let
  inherit (import ./lan-hosts.nix) lanHosts;
  hostEntry = lib.findFirst (h: h.hostname == config.networking.hostName) null lanHosts;
  hasIPv6 = hostEntry != null && hostEntry.ipv6 != null && hostEntry.mac != "";
in
{
  networking.networkmanager.enable = true;

  networking.networkmanager.ensureProfiles.profiles = lib.mkIf hasIPv6 {
    lan-wired = {
      connection = {
        id = "lan-wired";
        type = "ethernet";
        autoconnect = true;
        autoconnect-priority = 100;   # win over NM's default wired profile
      };
      # Bind to the known NIC by MAC so it attaches to the right interface
      # (mirrors the networkd matchConfig.MACAddress this replaces).
      ethernet.mac-address = lib.toUpper hostEntry.mac;
      ipv4 = {
        method = "auto";
        dhcp-client-id = "mac";       # match the MAC-keyed DHCP static lease
      };
      ipv6 = {
        method = "auto";              # SLAAC/RA (incl. RA /48 route-info)...
        addresses = "${hostEntry.ipv6}/64";   # ...plus the static AAAA address
      };
    };
  };
}
