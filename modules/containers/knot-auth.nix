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

  # TSIG identities allowed to write ACME DNS-01 challenges into the zone. Each
  # entry becomes a key, an ACL scoped to exactly one owner name and to TXT
  # records, and an entry in the zone's ACL list. `sopsName` is the
  # sops.secrets attribute this container's host renders the secret into.
  #
  # Hosts that hold the same secret run the ACME client:
  #   acme-homeassistant -> the HAOS box's certbot
  #   acme-garage        -> lego on lydia and wabbajack, one cert per node for
  #                         the shared name garage.home.garvey.sh
  #                         (modules/containers/garage.nix)
  #   acme-storj         -> lego on dragonsreach, for the S3 gateway container
  #                         running on that same host
  #                         (modules/containers/storj-gateway.nix)
  #   acme-rgw           -> lego on joor, zah and frul, one cert per node for
  #                         the shared name rgw.home.garvey.sh (Ceph RGW,
  #                         modules/services/ceph.nix). They are IPv6-only and
  #                         reach Knot through NAT64.
  acmeKeys = [
    {
      name = "acme-homeassistant";
      owner = "_acme-challenge.homeassistant.${domain}.";
      sopsName = "knot-acme-tsig";
      sopsFile = ../../secrets/dragonsreach.yaml;
      sopsKey = "knot-acme-tsig";
    }
    {
      name = "acme-garage";
      owner = "_acme-challenge.garage.${domain}.";
      sopsName = "garage-acme-tsig";
      sopsFile = ../../secrets/garage-acme.yaml;
      sopsKey = "acme_tsig_secret";
    }
    {
      name = "acme-storj";
      owner = "_acme-challenge.storj-gateway.${domain}.";
      sopsName = "storj-acme-tsig";
      sopsFile = ../../secrets/dragonsreach.yaml;
      sopsKey = "storj-acme-tsig";
    }
    {
      name = "acme-rgw";
      owner = "_acme-challenge.rgw.${domain}.";
      sopsName = "rgw-acme-tsig";
      sopsFile = ../../secrets/rgw-acme.yaml;
      sopsKey = "acme_tsig_secret";
    }
  ];

  # Zone serial must increase on every content change. The flake's lastModified
  # is monotonic across commits; max() with nixpkgs guards against a dirty tree
  # reporting 0 (same pattern as modules/desktop/mic-mute.nix).
  serial = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;

  zoneText = import ../networking/zone.nix { inherit lib domain serial; };
  zoneFile = pkgs.writeText "${domain}.zone" zoneText;
in
{
  imports = [ ./common.nix ];

  # TSIG keys for the ACME clients (RFC2136 / dns-rfc2136) to write their own
  # challenge records. Rendered on the host and bind-mounted in: knot.conf
  # itself lives in the world-readable Nix store, so the secrets go through
  # services.knot.keyFiles instead (that option exists precisely for this). The
  # matching ACLs below are what make the keys safe to hand out -- see the
  # comment there.
  sops.secrets = lib.listToAttrs (map (k: {
    name = k.sopsName;
    value = { inherit (k) sopsFile; key = k.sopsKey; };
  }) acmeKeys);

  # Built by explicit concatenation rather than a nested indented string: knot's
  # YAML subset wants the sequence indented under `key:`, and nix's indentation
  # stripping does not apply to an interpolated multi-line value.
  sops.templates."knot-acme-tsig.conf".content =
    "key:\n" + lib.concatMapStrings (k:
      "  - id: ${k.name}\n"
      + "    algorithm: hmac-sha256\n"
      + "    secret: ${config.sops.placeholder.${k.sopsName}}\n"
    ) acmeKeys;

  nspawn.network.knot-auth = {
    attachment = "bridge";
    hostBridge = "br-lan";
    localAddress = "10.28.0.6/16";
    ipv4Gateway = "10.28.0.1";
    ipv4Nameservers = [ "10.28.0.1" ];
    # No ipv4DefaultRoute and no IPv6: Knot only ever answers queries from the
    # LAN (blocky), from dnsdist, and from the ACME clients' RFC2136 updates. It
    # never initiates traffic, so it needs neither a default route nor
    # reachability outside br-lan.
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
      # that way: host and container uids are separate namespaces, so chowning it
      # to the container's knot uid would hand the TSIG keys to whichever host
      # account happens to hold that id. Instead root re-installs it as knot inside
      # the container, where the name resolves correctly. The `+` prefix runs this
      # as root even though knot.service drops to the knot user.
      systemd.services.knot.serviceConfig.ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -o knot -g knot -m 0400 /run/knot-acme-tsig.conf /run/knot/acme-tsig.conf"
      ];

      services.knot = {
        enable = true;
        # The TSIG secrets, included from a private copy of the bind-mounted sops
        # template rather than inlined into knot.conf (a world-readable store path).
        keyFiles = [ "/run/knot/acme-tsig.conf" ];
        settings = {
          server.listen = [ "0.0.0.0@53" "::@53" ];

          # Lets each ACME client write its own DNS-01 challenge, and nothing
          # else. A key is scoped to a single owner name and to TXT records, so
          # a compromise of the host holding it cannot repoint any real record in
          # this zone -- it can only write TXT at the one challenge name. That
          # scoping is what makes on-box issuance an acceptable substitute for
          # acme-dns, which otherwise exists to keep DDNS off the real zone. It
          # is also why one key can be shared by every garage node: the ACL is
          # scoped to the name they all write, not to a host.
          acl = lib.listToAttrs (map (k: {
            inherit (k) name;
            value = {
              key = k.name;
              action = [ "update" ];
              update-owner = "name";
              update-owner-match = "equal";
              update-owner-name = [ k.owner ];
              update-type = [ "TXT" ];
            };
          }) acmeKeys);

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
            acl = map (k: k.name) acmeKeys;
          };

          log.syslog.any = "info";
        };
      };

      system.stateVersion = "25.05";
    };
  };
}
