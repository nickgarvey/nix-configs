{ config, lib, pkgs, ... }:

# Alerting signal: does public DNS still publish this router's actual WAN IP?
#
# Every self-hosted zone is delegated to ns1 -> our WAN address, and acme-dns
# (which answers Let's Encrypt's DNS-01 challenges) is delegated the same way.
# That address is DHCP-assigned and hardcoded in three places with no DDNS
# automation: Cloudflare glue for home.garvey.sh, Cloudflare glue for
# acme.garvey.sh, and modules/networking/zone.nix. If the lease ever changes,
# Let's Encrypt can no longer reach our authoritative DNS and every renewal
# fails -- silently, for ~30 days, until certificates start expiring and
# TLS-verifying clients (the ESP32 devices pinned to Home Assistant) break.
#
# This emits the comparison as a metric so that failure becomes a page within
# minutes instead of a surprise a month later.

let
  cfg = config.routerConfig;

  # The records that publish this router's WAN IPv4 to the public internet.
  publishedRecords = [ "ns1.home.garvey.sh" "acme.garvey.sh" ];

  wanDnsCheck = pkgs.writeShellScript "wan-dns-check" ''
    set -u

    wan=$(${pkgs.iproute2}/bin/ip -4 -o addr show dev ${cfg.wanInterface} scope global \
      | ${pkgs.gawk}/bin/awk '{print $4}' \
      | ${pkgs.coreutils}/bin/cut -d/ -f1 \
      | ${pkgs.coreutils}/bin/head -1)

    # No WAN address at all: emit nothing rather than a bogus mismatch. The
    # absent() rule covers a check that stops reporting.
    [ -n "$wan" ] || exit 0

    for rec in ${lib.concatStringsSep " " publishedRecords}; do
      # Deliberately resolved through a PUBLIC resolver, never our own: this has
      # to reflect what Let's Encrypt sees, not our split-horizon view (kresd
      # short-circuits these zones to internal addresses -- see
      # knot-resolver.nix -- so asking locally would always look healthy).
      #
      # An empty answer counts as a mismatch on purpose: if the published glue
      # points somewhere that no longer answers, the recursive lookup SERVFAILs
      # rather than returning a wrong address, and renewals are just as broken.
      # Retried: a single timed-out lookup is a blip, not drift, and this feeds a
      # critical alert that places a phone call.
      pub=""
      for _ in 1 2 3; do
        pub=$(${pkgs.dnsutils}/bin/dig +short +time=3 +tries=2 @1.1.1.1 "$rec" A 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -E '^[0-9.]+$' \
          | ${pkgs.coreutils}/bin/head -1)
        [ -n "$pub" ] && break
        ${pkgs.coreutils}/bin/sleep 2
      done
      [ -n "$pub" ] || pub=none

      if [ "$pub" = "$wan" ]; then m=1; else m=0; fi
      echo "$rec $m $wan $pub"
    done
  '';
in
{
  config = {
    homelab.metrics.sources.wan_dns_drift = {
      type = "exec";
      mode = "scheduled";
      # Under Prometheus's 5-minute staleness window: these are pushed, not
      # scraped, so at 300s the series would expire between pushes and the
      # absent() alert would flap.
      scheduled.exec_interval_secs = 180;
      command = [ "${wanDnsCheck}" ];
    };

    homelab.metrics.transforms.wan_dns_drift_fields = {
      type = "remap";
      inputs = [ "wan_dns_drift" ];
      source = ''
        parts = split(strip_whitespace!(to_string!(.message)), " ")
        .record = parts[0]
        .value = to_int!(parts[1])
        .wan_ip = parts[2]
        .published_ip = parts[3]
        .info = 1
      '';
    };

    # The alerting series deliberately carries only `record`: one stable series
    # per record whose value flips 0/1. The addresses must NOT be labels here --
    # a failed lookup would then mint a *new* series (published_ip="none") that
    # sits at 0 alongside the healthy one at 1, so a momentary blip would look
    # like permanent drift and fire a critical alert that places a phone call.
    # The addresses are carried on a separate _info series instead, where label
    # churn is harmless because nothing alerts on it.
    homelab.metrics.transforms.wan_dns_drift_metric = {
      type = "log_to_metric";
      inputs = [ "wan_dns_drift_fields" ];
      metrics = [
        {
          type = "gauge";
          field = "value";
          name = "homelab_published_ip_matches_wan";
          tags = {
            record = "{{ record }}";
            hostname = config.networking.hostName;
          };
        }
        {
          type = "gauge";
          field = "info";
          name = "homelab_published_ip_info";
          tags = {
            record = "{{ record }}";
            wan_ip = "{{ wan_ip }}";
            published_ip = "{{ published_ip }}";
            hostname = config.networking.hostName;
          };
        }
      ];
    };
  };
}
