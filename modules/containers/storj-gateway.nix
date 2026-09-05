{ config, lib, pkgs, ... }:

# Storj single-tenant S3 gateway (libuplink-backed). Runs inside a
# systemd-nspawn container on the router's "router-side container" /64
# (2001:470:482f:300::/64). Dual-stack: libuplink needs native IPv4 to
# reach Storj storagenodes (predominantly v4); k3s pods reach the
# gateway over IPv6 via storj-gateway.home.garvey.sh.
#
# The access grant holds the encryption passphrase, so encryption
# happens here on the router before pieces are uploaded to the Storj
# satellites. Storj never sees plaintext.

let
  cfg = config.nspawn.storj-gateway;
  storjGatewayPkg = pkgs.callPackage ../../pkgs/storj-gateway-st { };

  # acmeNameserver is host:port; dig wants them apart. The zone lego needs the
  # SOA for is the domain's parent, which is the zone knot-auth serves.
  acmeNsHost = lib.head (lib.splitString ":" cfg.tls.acmeNameserver);
  acmeNsPort = lib.last (lib.splitString ":" cfg.tls.acmeNameserver);
  acmeZone = lib.concatStringsSep "." (lib.tail (lib.splitString "." cfg.tls.domain));
in
{
  imports = [ ./common.nix ];

  options.nspawn.storj-gateway = {
    tls = {
      enable = lib.mkEnableOption ''
        HTTPS on the S3 port instead of plaintext.

        gateway-st needs no reverse proxy: it hands minio `--config-dir` and
        no `--certs-dir`, so minio reads its certificate from
        <config-dir>/certs/{public.crt,private.key}. There is exactly one
        listener, so this converts port 7777 rather than adding a second one.

        Certificates are issued by lego on the host — DNS-01 against our own
        Knot, which runs on this same machine — and bind-mounted in. minio
        serves plain HTTP when the pair is absent, so an unissued or failed
        certificate degrades rather than taking the gateway down
      '';

      domain = lib.mkOption {
        type = lib.types.str;
        default = "storj-gateway.home.garvey.sh";
        description = ''
          Name the S3 endpoint is served under. Must be the name clients use,
          since that is what the certificate attests and what SigV4 signs —
          see the `storj-gateway` record in modules/networking/dns.nix.
        '';
      };

      acmeNameserver = lib.mkOption {
        type = lib.types.str;
        default = "10.28.0.6:53";
        description = ''
          Authoritative server lego sends its RFC2136 challenge updates to.
          This is the knot-auth container (modules/containers/knot-auth.nix),
          asked directly rather than through blocky so the update reaches the
          zone rather than a cache.
        '';
      };

      acmeTsigKeyName = lib.mkOption {
        type = lib.types.str;
        default = "acme-storj";
        description = ''
          TSIG key identity used for the challenge update. Must match an entry
          in `acmeKeys` in modules/containers/knot-auth.nix, whose ACL scopes
          it to `_acme-challenge.<domain>` and to TXT records only.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      nspawn.network.storj-gateway = {
        attachment = "bridge";
        hostBridge = "br-lan";
        localAddress = "10.28.0.3/16";
        localAddress6 = "2001:470:482f:300::2/64";
        hostBridgeAddress = "2001:470:482f:300::1";
        ipv4Gateway = "10.28.0.1";
        ipv4Nameservers = [ "10.28.0.1" ];
      };

      sops.secrets.storj-access-grant = {
        sopsFile = ../../secrets/storj-gateway.yaml;
        key = "storj_access_grant";
      };
      sops.secrets.storj-s3-access-key = {
        sopsFile = ../../secrets/storj-gateway.yaml;
        key = "storj_s3_access_key";
      };
      sops.secrets.storj-s3-secret-key = {
        sopsFile = ../../secrets/storj-gateway.yaml;
        key = "storj_s3_secret_key";
      };

      sops.templates."storj-gateway.env".content = ''
        STORJ_ACCESS=${config.sops.placeholder.storj-access-grant}
        GATEWAY_S3_ACCESS_KEY=${config.sops.placeholder.storj-s3-access-key}
        GATEWAY_S3_SECRET_KEY=${config.sops.placeholder.storj-s3-secret-key}
      '';

      containers.storj-gateway = {
        bindMounts = {
          "/run/storj-gateway.env" = {
            hostPath = config.sops.templates."storj-gateway.env".path;
            isReadOnly = true;
          };
        } // lib.optionalAttrs cfg.tls.enable {
          # The host's lego writes here; the import unit below copies out of it.
          # The directory is guaranteed to exist before the container starts by
          # the tmpfiles rule, so a boot before the first issuance still works.
          "/run/storj-tls" = {
            hostPath = "/var/lib/acme/${cfg.tls.domain}";
            isReadOnly = true;
          };
        };

        config = { config, pkgs, lib, ... }: {
          users.users.storj-gateway = {
            isSystemUser = true;
            group = "storj-gateway";
            home = "/var/lib/storj-gateway";
            createHome = true;
          };
          users.groups.storj-gateway = { };

          # libuplink reaches Storj satellites by IP. DNS returns AAAA records
          # synthesized via NAT64 (64:ff9b::/96 maps to the satellite's IPv4),
          # which is the router's translator namespace. The container needs
          # an explicit route to 64:ff9b::/96 via the host bridge — same
          # mechanism as the intra-site /48 route, but a different prefix.
          systemd.services."nspawn-nat64-route6" = {
            description = "Route NAT64 prefix via host bridge for libuplink";
            wantedBy = [ "multi-user.target" ];
            before = [ "storj-gateway.service" ];
            after = [ "network-addresses-eth0.service" ];
            wants = [ "network-addresses-eth0.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${pkgs.iproute2}/bin/ip -6 route replace 64:ff9b::/96 via 2001:470:482f:300::1 dev eth0
            '';
          };

          # Copies the host-issued pair into the names and location minio looks
          # for. Deliberately not RemainAfterExit: it re-runs on every gateway
          # start, so the host's renewal hook only has to restart the gateway.
          #
          # Installing nothing leaves the gateway on plain HTTP, which is the
          # intended degradation. Installing something minio cannot load is
          # fatal instead — it aborts at startup rather than falling back — so
          # this only copies a pair minio will accept.
          #
          # The case that matters is security.acme's minica placeholder: until
          # the first order succeeds it plants a self-signed cert with a P-384
          # key, and minio rejects P-384 and P-521 (Go has no constant-time
          # implementation; storj.io/minio cmd/config/certs.go:102). Copying it
          # turns a failed ACME order into a dead S3 gateway.
          systemd.services.storj-tls-import = lib.mkIf cfg.tls.enable {
            description = "Install the host-issued TLS certificate for the gateway";
            before = [ "storj-gateway.service" ];
            requiredBy = [ "storj-gateway.service" ];
            serviceConfig.Type = "oneshot";
            path = [ pkgs.coreutils pkgs.openssl ];
            script = ''
              certs=/var/lib/storj-gateway/minio/certs

              # Declining to install is not enough on its own: whatever was
              # installed last time stays until it is removed, so a gateway that
              # once got a bad pair would keep crashing on it. Every path that
              # does not install clears instead, which leaves minio on HTTP.
              serve_plaintext() {
                rm -f "$certs/public.crt" "$certs/private.key"
                exit 0
              }

              if [ ! -f /run/storj-tls/fullchain.pem ] || [ ! -f /run/storj-tls/key.pem ]; then
                echo "No certificate present; the gateway will serve plain HTTP."
                serve_plaintext
              fi

              # Empty for an RSA key, which minio accepts at any size.
              curve=$(openssl ec -in /run/storj-tls/key.pem -noout -text 2>/dev/null \
                | sed -n 's/^NIST CURVE: //p')
              case "$curve" in
                P-384 | P-521)
                  echo "Certificate key uses $curve, which minio rejects."
                  echo "This is what the pre-issuance self-signed placeholder looks like."
                  echo "Serving plain HTTP until a real certificate is issued."
                  serve_plaintext
                  ;;
              esac

              install -d -o storj-gateway -g storj-gateway -m 0700 "$certs"
              install -o storj-gateway -g storj-gateway -m 0400 \
                /run/storj-tls/fullchain.pem "$certs/public.crt"
              install -o storj-gateway -g storj-gateway -m 0400 \
                /run/storj-tls/key.pem "$certs/private.key"
            '';
          };

          systemd.services.storj-gateway = {
            description = "Storj single-tenant S3 gateway";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "simple";
              User = "storj-gateway";
              Group = "storj-gateway";
              EnvironmentFile = "/run/storj-gateway.env";
              ExecStart = ''
                ${storjGatewayPkg}/bin/gateway run \
                  --access ''${STORJ_ACCESS} \
                  --minio.access-key ''${GATEWAY_S3_ACCESS_KEY} \
                  --minio.secret-key ''${GATEWAY_S3_SECRET_KEY} \
                  --server.address [::]:7777 \
                  --config-dir /var/lib/storj-gateway
              '';
              Restart = "on-failure";
              RestartSec = "10s";

              # Hardening
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              ReadWritePaths = [ "/var/lib/storj-gateway" ];
            };
          };
        };
      };
    }

    (lib.mkIf cfg.tls.enable {
      # Certificate issuance for the endpoint the gateway serves inside the
      # container. DNS-01 against our own Knot over RFC2136, the same mechanism
      # Home Assistant and the garage nodes use; the TSIG key is scoped to
      # `_acme-challenge.<domain>` and TXT records only
      # (modules/containers/knot-auth.nix). Knot runs on this same host, in the
      # knot-auth container.
      sops.secrets.storj-acme-tsig = {
        sopsFile = ../../secrets/dragonsreach.yaml;
        key = "storj-acme-tsig";
      };

      sops.templates."storj-acme.env".content = ''
        RFC2136_NAMESERVER=${cfg.tls.acmeNameserver}
        RFC2136_TSIG_KEY=${cfg.tls.acmeTsigKeyName}
        RFC2136_TSIG_ALGORITHM=hmac-sha256.
        RFC2136_TSIG_SECRET=${config.sops.placeholder.storj-acme-tsig}
      '';

      security.acme = {
        acceptTerms = true;
        defaults.email = "garvey.nick@gmail.com";
        certs.${cfg.tls.domain} = {
          dnsProvider = "rfc2136";
          dnsResolver = cfg.tls.acmeNameserver;
          environmentFile = config.sops.templates."storj-acme.env".path;
          # Skip lego's "have all authoritative nameservers got the record yet"
          # wait. That check ignores dnsResolver: it resolves the zone's NS
          # (ns1 -> our WAN address) and queries that. From the LAN the :53
          # DNAT does not apply — it matches on the WAN interface — so the
          # query lands on blocky instead of dnsdist, and blocky's 1m negative
          # cache (modules/router/blocky-dns.nix) outlives lego's 60s
          # propagation timeout. Same dead end knot-resolver.nix documents for
          # acme.garvey.sh.
          #
          # Nothing is lost by skipping it: Knot is the only authoritative
          # server, and its DDNS update is committed before lego moves on, so
          # there is no propagation to await. Let's Encrypt validates from the
          # public internet, where the DNAT does apply and dnsdist reaches
          # Knot directly.
          dnsPropagationCheck = false;
          # Runs as root in the acme unit's ExecStartPost, and only on an actual
          # renewal. minio reads its certificate at startup, and the import unit
          # re-runs on every gateway start, so a restart is what picks up the
          # new one. `|| true` so a stopped container cannot fail the renewal
          # that already succeeded.
          postRun = ''
            ${pkgs.systemd}/bin/systemctl -M storj-gateway restart storj-gateway.service || true
          '';
        };
      };

      # lego looks up the zone's SOA before it can send the challenge update,
      # and the server it asks — knot-auth — is a container on this same host.
      # Unlike the garage nodes, which query it across the LAN and find it
      # already up, a rebuild here restarts both units at once: an order that
      # starts first gets an ICMP port-unreachable, fails, and spends one of
      # Let's Encrypt's failed-validation slots. Waiting for the container unit
      # narrows that; waiting for Knot to actually answer closes it.
      systemd.services."acme-order-renew-${cfg.tls.domain}" = {
        after = [ "container@knot-auth.service" ];
        preStart = ''
          for _ in $(seq 1 30); do
            if [ -n "$(${pkgs.dnsutils}/bin/dig +noall +answer +timeout=2 \
                @${acmeNsHost} -p ${acmeNsPort} ${acmeZone} SOA)" ]; then
              exit 0
            fi
            sleep 1
          done
          echo "${acmeZone} SOA unanswered by ${cfg.tls.acmeNameserver} after 30s; ordering anyway."
        '';
      };

      # nspawn needs the bind-mount source to exist at container start, which
      # can precede the first issuance. acme owns it so lego's own units are
      # free to manage what is inside.
      systemd.tmpfiles.rules = [
        "d /var/lib/acme/${cfg.tls.domain} 0750 acme acme -"
      ];
    })
  ];
}
