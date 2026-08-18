# DNS records for the local zone (home.garvey.sh).
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
    dragonsreach  = { v4 = [ "10.28.0.1" ];    v6 = [ "2001:470:482f::1" ]; };
    frigate       = { v4 = [ "10.28.12.109" ]; v6 = []; };
    smb           = { v4 = [ "10.28.12.110" ]; v6 = [ "2001:470:482f::14" ]; };
    # Both garage nodes. Clients round-robin; any node serves the whole S3 API.
    # Peer-to-peer RPC does not use this — see modules/containers/garage.nix.
    garage        = { v4 = []; v6 = [ "2001:470:482f:200::2" "2001:470:482f:202::2" ]; };
    storj-gateway = { v4 = [ "10.28.0.3" ]; v6 = [ "2001:470:482f:300::2" ]; };
    k3s-api       = { v4 = []; v6 = map hostV6 [ "fus" "ro" "dah" ]; };
    # trmnl-display keeps A+AAAA: the ESP32 client is IPv4-only and hits an
    # IPv4→IPv6 proxy at 10.28.0.2. The AAAA is for dual-stack clients.
    trmnl-display = { v4 = [ "10.28.0.2" ]; v6 = [ "2001:470:482f:2::5" ]; };
    # A Caddy sidecar in the anki pod terminates TLS on 443 off this LB IP.
    anki          = { v4 = []; v6 = [ "2001:470:482f:2::5003" ]; };
  };

  # CNAMEs (targets are FQDNs with trailing dot).
  cnames = {
    "_acme-challenge.anki" = "0a95fd7d-b7d2-4827-96df-65575900f9ac.acme.garvey.sh.";
  };

  # Split-horizon overrides: public (garvey.sh) names answered internally with
  # in-cluster LB IPs, so TLS-verified internal access name-matches the cert
  # instead of hairpinning to the public IP. Keys are full FQDNs. Add future
  # public-named services here to keep this declarative. Everything else under
  # garvey.sh still resolves via the normal upstream (public) path.
  garveyShOverrides = {
    "oci.garvey.sh" = "2001:470:482f:2::5000";
    "jellyfin.garvey.sh" = "2001:470:482f:2::5001";
    "temporal.garvey.sh" = "2001:470:482f:2::5002";
  };
}
