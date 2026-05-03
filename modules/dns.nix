# DNS records for the local zone (home.arpa).
# Consumed by: blocky DNS (router).
#
# Split from lan-hosts.nix so that "physical host" data (MAC → IP for DHCP)
# is separate from "DNS records" data (what names point where). Supports
# multi-IP (e.g. k3s-api HA round-robin) natively via list-valued fields,
# and references into lanHosts to avoid duplicating IPs.
{ lib }:

let
  inherit (import ./lan-hosts.nix) lanHosts;
  hostV6 = name:
    let h = lib.findFirst (h: h.hostname == name)
              (throw "dns.nix: unknown host '${name}'") lanHosts;
    in h.ipv6;
in rec {
  # A/AAAA records. v4/v6 are lists; empty list = no record of that family.
  records = {
    router        = { v4 = [ "10.28.0.1" ];    v6 = [ "2001:470:482f::1" ]; };
    frigate       = { v4 = [ "10.28.12.109" ]; v6 = []; };
    smb           = { v4 = [ "10.28.12.110" ]; v6 = [ "2001:470:482f::14" ]; };
    garage        = { v4 = [];                 v6 = [ "2001:470:482f::15" ]; };
    k3s-api       = { v4 = []; v6 = map hostV6 [ "k3s-node-1" "k3s-node-2" "k3s-node-3" ]; };
    # trmnl-display keeps A+AAAA: the ESP32 client is IPv4-only and hits an
    # IPv4→IPv6 proxy at 10.28.0.2. The AAAA is for dual-stack clients.
    trmnl-display = { v4 = [ "10.28.0.2" ]; v6 = [ "2001:470:482f:2::5" ]; };
  };

  # CNAMEs (targets are FQDNs with trailing dot).
  cnames = {
    plex      = "plex.plex.k8s.home.arpa.";
    zot       = "zot.zot.k8s.home.arpa.";
    llama-cpp = "framework-desktop.home.arpa.";
  };
}
