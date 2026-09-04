{ config, lib, pkgs, ... }:

let
  cfg = config.nspawn.garage;
in
{
  imports = [ ./common.nix ];

  options.nspawn.garage = {
    localAddress6 = lib.mkOption {
      type = lib.types.str;
      description = "IPv6 address with prefix length for the garage container.";
    };

    hostBridge = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge interface for the container network.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = "Host path for garage data (bind-mounted as /var/lib/garage).";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Short identifier for this node, used as its garage layout zone.";
    };

    capacity = lib.mkOption {
      type = lib.types.str;
      default = "1T";
      description = "Capacity to advertise to the garage layout for this node.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Peer entries of the form <node_id>@[<ipv6>]:3901, used as
        bootstrap_peers. Garage dials these itself and retries until they
        answer.

        Literal addresses, not names: the container's only resolver is blocky
        on the router, so a name here would make cluster formation depend on
        the DNS service being up first.
      '';
    };

    replicationFactor = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = ''
        Garage replication factor. Must match the RF persisted in the
        cluster layout — garage refuses to start on mismatch, and there is
        no online command to change it (`garage layout config -r` sets zone
        redundancy, a different parameter). Changing RF means rebuilding the
        layout: stop every node, delete `meta/cluster_layout` on each,
        redeploy with the new value, then let the layout be assigned afresh.
        A layout also cannot have fewer capacity-carrying nodes than the RF,
        so shrinking the cluster below the RF requires the same procedure.
      '';
    };

    hostBridgeAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host's vmbr0 IPv6 address in the same /64 as localAddress6. Used as
        the next-hop for the container's intra-site /48 IPv6 route, so the
        container can reach the rest of 2001:470:482f::/48 (router, k3s
        nodes, garage peers) via the host. NOT a default route — HE prefix
        reputation; see modules/router/lan-ipv6.nix.
      '';
    };

    tls = {
      enable = lib.mkEnableOption ''
        an HTTPS listener for the S3 API on port 443, in addition to the
        plaintext API on 3900 (which is left untouched).

        Garage speaks no TLS itself, so nginx in the container terminates it
        and proxies to garage on the loopback. The container has no route to
        the internet (see common.nix), so the certificate is issued by lego on
        the *host* — DNS-01 against our own Knot — and bind-mounted in.

        Every node serves the same name, so a client that lands on any of the
        round-robin addresses verifies identically. Each node issues its own
        copy of the certificate; nothing but the TSIG key is shared
      '';

      domain = lib.mkOption {
        type = lib.types.str;
        default = "garage.home.garvey.sh";
        description = ''
          Name the S3 endpoint is served under. Must be the name clients use,
          since that is what the certificate attests and what SigV4 signs —
          see the `garage` record in modules/networking/dns.nix.
        '';
      };

      acmeNameserver = lib.mkOption {
        type = lib.types.str;
        default = "10.28.0.6:53";
        description = ''
          Authoritative server lego sends its RFC2136 challenge updates to,
          and checks propagation against. This is the knot-auth container
          (modules/containers/knot-auth.nix), asked directly rather than
          through blocky so the check sees the zone, not a cache.
        '';
      };

      acmeTsigKeyName = lib.mkOption {
        type = lib.types.str;
        default = "acme-garage";
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
      sops.secrets.garage-rpc-secret = {
        sopsFile = ../../secrets/garage.yaml;
        key = "garage_rpc_secret";
      };
      sops.secrets.garage-admin-token = {
        sopsFile = ../../secrets/garage.yaml;
        key = "garage_admin_token";
      };
      sops.secrets.garage-s3-access-key = {
        sopsFile = ../../secrets/garage.yaml;
        key = "garage_s3_access_key";
      };
      sops.secrets.garage-s3-secret-key = {
        sopsFile = ../../secrets/garage.yaml;
        key = "garage_s3_secret_key";
      };

      sops.templates."garage.env".content = ''
        GARAGE_RPC_SECRET=${config.sops.placeholder.garage-rpc-secret}
        GARAGE_ADMIN_TOKEN=${config.sops.placeholder.garage-admin-token}
        GARAGE_S3_ACCESS_KEY=${config.sops.placeholder.garage-s3-access-key}
        GARAGE_S3_SECRET_KEY=${config.sops.placeholder.garage-s3-secret-key}
      '';

      nspawn.network.garage = {
        attachment = "bridge";
        hostBridge = cfg.hostBridge;
        localAddress6 = cfg.localAddress6;
        hostBridgeAddress = cfg.hostBridgeAddress;
      };

      containers.garage = {
        bindMounts = {
          "/var/lib/garage" = {
            hostPath = cfg.dataPath;
            isReadOnly = false;
          };
          "/run/garage.env" = {
            hostPath = config.sops.templates."garage.env".path;
            isReadOnly = true;
          };
        } // lib.optionalAttrs cfg.tls.enable {
          # The host's lego writes here; nginx inside reads it. The directory is
          # guaranteed to exist before the container starts by the tmpfiles rule
          # below, so a node that has never issued a cert still boots.
          "/run/garage-tls" = {
            hostPath = "/var/lib/acme/${cfg.tls.domain}";
            isReadOnly = true;
          };
        };

        config = { config, pkgs, lib, ... }: {
          services.garage = {
            enable = true;
            package = pkgs.garage;
            environmentFile = "/run/garage.env";
            settings = {
              metadata_dir = "/var/lib/garage/meta";
              data_dir = "/var/lib/garage/data";
              db_engine = "lmdb";
              replication_factor = cfg.replicationFactor;
              consistency_mode = "consistent";

              rpc_bind_addr = "[::]:3901";
              # The container's own address, so peers need no name resolution.
              rpc_public_addr = "[${lib.head (lib.splitString "/" cfg.localAddress6)}]:3901";
              bootstrap_peers = cfg.peers;

              s3_api = {
                s3_region = "garage";
                api_bind_addr = "[::]:3900";
              };

              admin = {
                api_bind_addr = "[::]:3903";
              };
            };
          };

          # Only the cluster-origin node (no peers) bootstraps itself. A node that
          # has peers needs nothing here: garage dials bootstrap_peers itself and
          # retries until they answer, and role/bucket/key setup on a joining node
          # is an operator's `garage layout assign`.
          systemd.services.garage-init = lib.mkIf (cfg.peers == [ ]) {
            description = "Initialize Garage layout, bucket, and API key";
            after = [ "garage.service" ];
            requires = [ "garage.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              EnvironmentFile = "/run/garage.env";
              Restart = "on-failure";
              RestartSec = "5s";
            };
            path = [ pkgs.garage pkgs.gnugrep pkgs.gawk pkgs.coreutils ];
            script = ''
              # Fails if garage isn't ready yet; systemd will retry.
              NODE_ID=$(garage node id | cut -c1-16)

              if ! garage layout show | awk '/^==== CURRENT CLUSTER LAYOUT ====/{f=1;next} /^$/{f=0} f && /^[0-9a-f]/{print $1}' | grep -q "^$NODE_ID"; then
                CURRENT_VERSION=$(garage layout show | awk '/Current cluster layout version:/ {print $NF}')
                garage layout assign -z ${cfg.hostname} -c ${cfg.capacity} "$NODE_ID"
                garage layout apply --version $(( CURRENT_VERSION + 1 ))
              fi

              if ! garage bucket list | grep -q "default"; then
                garage bucket create default
              fi

              if ! garage key list | grep -q "garage-key"; then
                garage key import -n garage-key --yes "$GARAGE_S3_ACCESS_KEY" "$GARAGE_S3_SECRET_KEY"
              fi

              garage bucket allow --read --write --owner default --key garage-key
            '';
          };

          # DynamicUser (garage module default) conflicts with bind-mounted /var/lib/garage
          systemd.services.garage.serviceConfig.DynamicUser = lib.mkForce false;

          # nginx runs wholly as the `nginx` user, so it cannot read the
          # bind-mounted cert (0640 acme:acme on the host, and the host's gids
          # mean nothing in here anyway). Root re-installs a private copy for it.
          #
          # Its own unit rather than an ExecStartPre on nginx, so the copy is
          # ordered ahead of anything else nginx's own unit does and does not
          # depend on where nixpkgs' ExecStartPre list happens to merge. No
          # RemainAfterExit: it re-runs on every nginx start, which is how a
          # renewed cert gets picked up (the host just restarts nginx).
          systemd.services.garage-tls-import = lib.mkIf cfg.tls.enable {
            description = "Install the host-issued TLS certificate for nginx";
            before = [ "nginx.service" ];
            requiredBy = [ "nginx.service" ];
            serviceConfig.Type = "oneshot";
            path = [ pkgs.coreutils ];
            script = ''
              install -d -o nginx -g nginx -m 0700 /run/garage-nginx-tls
              install -o nginx -g nginx -m 0400 \
                /run/garage-tls/fullchain.pem /run/garage-nginx-tls/fullchain.pem
              install -o nginx -g nginx -m 0400 \
                /run/garage-tls/key.pem /run/garage-nginx-tls/key.pem
            '';
          };

          services.nginx = lib.mkIf cfg.tls.enable {
            enable = true;
            recommendedTlsSettings = true;
            # The validator is gixy (and nginxfmt) only — it runs no `nginx -t`,
            # so nothing is lost but the lint. Gixy rejects `Host $http_host` as
            # host spoofing, which is advice for a backend that makes trust
            # decisions on Host. Garage does not: it uses Host to verify the
            # SigV4 signature, so forwarding anything but what the client signed
            # is what would actually break.
            validateConfigFile = false;
            # recommendedProxySettings is deliberately off: it sets
            # `Host $host`, which drops the port. SigV4 signs the Host header the
            # client sent, so it has to be forwarded verbatim.
            virtualHosts.${cfg.tls.domain} = {
              onlySSL = true;
              listen = [ { addr = "[::]"; port = 443; ssl = true; } ];
              sslCertificate = "/run/garage-nginx-tls/fullchain.pem";
              sslCertificateKey = "/run/garage-nginx-tls/key.pem";
              locations."/" = {
                proxyPass = "http://[::1]:3900";
                extraConfig = ''
                  proxy_set_header Host $http_host;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_http_version 1.1;

                  # S3 objects are arbitrarily large and streamed. Buffering a
                  # PUT to disk before forwarding it would cap throughput and
                  # fill the container's root filesystem.
                  client_max_body_size 0;
                  proxy_request_buffering off;
                  proxy_buffering off;
                  proxy_max_temp_file_size 0;
                '';
              };
            };
          };
        };
      };
    }

    (lib.mkIf cfg.tls.enable {
      # Certificate issuance for the endpoint nginx serves inside the container.
      # DNS-01 against our own Knot over RFC2136, the same mechanism Home
      # Assistant uses; the TSIG key is scoped to `_acme-challenge.<domain>` and
      # TXT records only (modules/containers/knot-auth.nix), which is what makes
      # it safe to hold on every garage node.
      #
      # Nodes issue independently, so a cluster-wide simultaneous first
      # issuance spends one of Let's Encrypt's 5-per-week duplicate
      # certificates per node. Renewals are staggered by their own expiry and
      # come nowhere near it.
      sops.secrets.garage-acme-tsig = {
        sopsFile = ../../secrets/garage-acme.yaml;
        key = "acme_tsig_secret";
      };

      sops.templates."garage-acme.env".content = ''
        RFC2136_NAMESERVER=${cfg.tls.acmeNameserver}
        RFC2136_TSIG_KEY=${cfg.tls.acmeTsigKeyName}
        RFC2136_TSIG_ALGORITHM=hmac-sha256.
        RFC2136_TSIG_SECRET=${config.sops.placeholder.garage-acme-tsig}
      '';

      security.acme = {
        acceptTerms = true;
        defaults.email = "garvey.nick@gmail.com";
        certs.${cfg.tls.domain} = {
          dnsProvider = "rfc2136";
          dnsResolver = cfg.tls.acmeNameserver;
          environmentFile = config.sops.templates."garage-acme.env".path;
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
          # renewal. nginx reads its certificate at startup, and the import unit
          # that copies it in re-runs on every nginx start, so a restart is what
          # picks up the new one. `|| true` so a stopped container cannot fail
          # the renewal that already succeeded.
          postRun = ''
            ${pkgs.systemd}/bin/systemctl -M garage restart nginx.service || true
          '';
        };
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
