{ config, lib, pkgs, ... }:

# End-to-end check of the certificate Home Assistant actually serves.
#
# cert-manager renewing successfully is necessary but not sufficient: the cert
# still has to be copied out to HAOS and picked up by a restart. If that sync
# breaks, cert-manager looks perfectly healthy while HA serves something stale.
#
# Expiry alone is a weak signal here -- the hand-issued XCA certificate this
# setup is replacing was valid until 2030, so an expiry check would have
# reported "healthy" for four years while HA served a certificate that was for
# the wrong hostname and chained to a private CA. So this asserts validity
# (hostname match + chain to a trusted root) as well as remaining lifetime.

let
  haHost = "homeassistant.home.garvey.sh";
  haPort = 8123;

  haCertProbe = pkgs.writeShellScript "ha-cert-probe" ''
    set -u

    # -verify_return_error turns a chain failure into a non-zero exit;
    # -verify_hostname additionally rejects a cert that is valid but issued for
    # some other name (exactly the pre-migration failure mode).
    if out=$(${pkgs.openssl}/bin/openssl s_client \
               -connect ${haHost}:${toString haPort} \
               -servername ${haHost} \
               -verify_hostname ${haHost} \
               -verify_return_error \
               -brief </dev/null 2>&1); then
      valid=1
    else
      valid=0
    fi

    # Read the expiry even when verification failed -- knowing how long the
    # *wrong* cert has left is useful while a migration is in flight.
    end=$(${pkgs.openssl}/bin/openssl s_client \
            -connect ${haHost}:${toString haPort} \
            -servername ${haHost} </dev/null 2>/dev/null \
          | ${pkgs.openssl}/bin/openssl x509 -noout -enddate 2>/dev/null \
          | ${pkgs.coreutils}/bin/cut -d= -f2)

    # Unreachable endpoint: emit nothing. The absent() rule covers silence, and a
    # fabricated 0 here would be indistinguishable from a real expiry.
    [ -n "$end" ] || exit 0
    epoch=$(${pkgs.coreutils}/bin/date -d "$end" +%s 2>/dev/null) || exit 0

    echo "$valid $epoch"
  '';
in
{
  config = {
    homelab.metrics.sources.ha_cert_probe = {
      type = "exec";
      mode = "scheduled";
      # Must stay comfortably under Prometheus's 5-minute staleness window --
      # these are pushed, not scraped, so a longer interval leaves the series
      # absent between pushes and the absent() alert flaps.
      scheduled.exec_interval_secs = 180;
      command = [ "${haCertProbe}" ];
    };

    homelab.metrics.transforms.ha_cert_probe_fields = {
      type = "remap";
      inputs = [ "ha_cert_probe" ];
      source = ''
        parts = split(strip_whitespace!(to_string!(.message)), " ")
        .valid = to_int!(parts[0])
        .expiry = to_int!(parts[1])
      '';
    };

    homelab.metrics.transforms.ha_cert_probe_metric = {
      type = "log_to_metric";
      inputs = [ "ha_cert_probe_fields" ];
      metrics = [
        {
          type = "gauge";
          field = "valid";
          name = "homelab_ha_served_cert_valid";
          tags = {
            host = haHost;
            hostname = config.networking.hostName;
          };
        }
        {
          type = "gauge";
          field = "expiry";
          name = "homelab_ha_served_cert_expiry_seconds";
          tags = {
            host = haHost;
            hostname = config.networking.hostName;
          };
        }
      ];
    };
  };
}
