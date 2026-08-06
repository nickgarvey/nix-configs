{ config, lib, pkgs, inputs, ... }:

# Authoritative DNS for home.garvey.sh (Knot), the zone we serve ourselves.
#
# Blocky owns :53 on the router host (all interfaces), so this can't live on the
# host directly -- it runs in a dedicated nspawn container with its own LAN IPv4,
# mirroring public-dns-proxy. LAN queries arrive via knot-resolver's forward stub
# (modules/router/knot-resolver.nix), which blocky uses as its upstream; public
# queries arrive via the router's WAN :53 DNAT into public-dns-proxy's dnsdist.
#
# Knot is authoritative-only: it answers for this zone and returns a referral for
# the k8s.home.garvey.sh subzone. It never recurses and never forwards.

let
  domain = "home.garvey.sh";

  # TSIG identity used by Home Assistant's certbot for DNS-01.
  acmeKeyName = "acme-homeassistant";
  acmeChallengeOwner = "_acme-challenge.homeassistant.${domain}.";

  # Zone serial must increase on every content change. The flake's lastModified
  # is monotonic across commits; max() with nixpkgs guards against a dirty tree
  # reporting 0 (same pattern as modules/desktop/mic-mute.nix).
  serial = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;

  zoneText = import ../networking/zone.nix { inherit lib domain serial; };
  zoneFile = pkgs.writeText "${domain}.zone" zoneText;
in
{
  imports = [ ./common.nix ];

  # TSIG key for the Home Assistant box's certbot (RFC2136 / dns-rfc2136) to
  # write its own ACME challenge records. Rendered on the host and bind-mounted
  # in: knot.conf itself lives in the world-readable Nix store, so the secret
  # goes through services.knot.keyFiles instead (that option exists precisely
  # for this). The matching ACL below is what makes the key safe to hand out --
  # see the comment there.
  sops.secrets.knot-acme-tsig = {
    sopsFile = ../../secrets/dragonsreach.yaml;
    key = "knot-acme-tsig";
  };

  sops.templates."knot-acme-tsig.conf".content = ''
    key:
      - id: ${acmeKeyName}
        algorithm: hmac-sha256
        secret: ${config.sops.placeholder.knot-acme-tsig}
  '';

  nspawn.network.knot-auth = {
    attachment = "bridge";
    hostBridge = "br-lan";
    localAddress = "10.28.0.6/16";
    ipv4Gateway = "10.28.0.1";
    ipv4Nameservers = [ "10.28.0.1" ];
    # No ipv4DefaultRoute and no IPv6: Knot only ever answers queries from the
    # LAN (blocky) and, later, from dnsdist. It never initiates traffic, so it
    # needs neither a default route nor reachability outside br-lan.
  };

  containers.knot-auth = {
    bindMounts."/run/knot-acme-tsig.conf" = {
      hostPath = config.sops.templates."knot-acme-tsig.conf".path;
      isReadOnly = true;
    };

    # The zone file lives in the Nix store, which nspawn bind-mounts read-only
    # into the container -- so a config change is a store path change.
    config = { config, pkgs, ... }: {
      # The bind-mounted sops template is 0400 root:root on the host and must stay
      # that way: the host's uid 999 is `kea`, not `knot`, so chowning it to the
      # container's knot uid would hand the TSIG key to the DHCP daemon. Instead
      # root re-installs it as knot inside the container, where uid 999 really is
      # knot. The `+` prefix runs this as root even though knot.service drops to
      # the knot user.
      systemd.services.knot.serviceConfig.ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -o knot -g knot -m 0400 /run/knot-acme-tsig.conf /run/knot/acme-tsig.conf"
      ];

      services.knot = {
        enable = true;
        # The TSIG secret, included from a private copy of the bind-mounted sops
        # template rather than inlined into knot.conf (a world-readable store path).
        keyFiles = [ "/run/knot/acme-tsig.conf" ];
        settings = {
          server.listen = [ "0.0.0.0@53" "::@53" ];

          # Lets Home Assistant's certbot write its own DNS-01 challenge, and
          # nothing else. The key is scoped to a single owner name and to TXT
          # records, so a compromise of the HA box cannot repoint any real record
          # in this zone -- it can only write TXT at the one challenge name. That
          # scoping is what makes on-box issuance an acceptable substitute for
          # acme-dns, which otherwise exists to keep DDNS off the real zone.
          acl.${acmeKeyName} = {
            key = acmeKeyName;
            action = [ "update" ];
            update-owner = "name";
            update-owner-match = "equal";
            update-owner-name = [ acmeChallengeOwner ];
            update-type = [ "TXT" ];
          };

          template.default = {
            # Input-only zone file: it lives in the Nix store and must never be
            # rewritten. -1 disables flushing the journal back to it.
            zonefile-sync = -1;
            # "difference" + journal-content "changes" so the dynamic ACME TXT
            # records survive a reload. Under "whole" a config change would
            # reload the store file verbatim and silently wipe an in-flight
            # challenge, failing the renewal.
            zonefile-load = "difference";
            journal-content = "changes";
          };

          # Absolute path, so Knot's `storage` stays at its default /var/lib/knot
          # (StateDirectory, writable) for the journal and any future kasp-db.
          # Pointing `storage` at the store instead would make those unwritable.
          zone.${domain} = {
            file = toString zoneFile;
            acl = [ acmeKeyName ];
          };

          log.syslog.any = "info";
        };
      };

      system.stateVersion = "25.05";
    };
  };
}
