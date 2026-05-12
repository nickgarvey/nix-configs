{ config, lib, pkgs, ... }:

let
  cfg = config.nspawn.garage;
in
{
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
      description = ''
        Short identifier for this node. Used as the garage layout zone and
        as the DNS suffix for rpc_public_addr (garage-<hostname>.home.arpa).
      '';
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
        Peer entries of the form <node_id>@<dns-name>:3901. Used as
        bootstrap_peers and re-asserted via `garage node connect` on startup.
      '';
    };

    replicationFactor = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = ''
        Garage replication factor. Must match the cluster's persisted RF —
        garage refuses to start on mismatch. To migrate an existing RF=1
        cluster to RF=2: first deploy with this set to 1 on both hosts,
        join the second node, run `garage layout config -r 2`, then bump
        this to 2 and redeploy.
      '';
    };
  };

  config = {
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

    containers.garage = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress6 = cfg.localAddress6;

      bindMounts = {
        "/var/lib/garage" = {
          hostPath = cfg.dataPath;
          isReadOnly = false;
        };
        "/run/garage.env" = {
          hostPath = config.sops.templates."garage.env".path;
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
            rpc_public_addr = "garage-${cfg.hostname}.home.arpa:3901";
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

        systemd.services.garage-init = {
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

            # Re-assert peer connections (idempotent).
            ${lib.concatMapStringsSep "\n" (p: ''
              garage node connect ${p} || true
            '') cfg.peers}

            ${if cfg.peers == [] then ''
              # Standalone-bootstrap host: auto-assign self a role and seed
              # buckets/keys if missing. Only safe when this node is the
              # cluster origin (peers list empty).
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
            '' else ''
              # Joining an existing cluster — role/bucket/key setup is the
              # responsibility of an operator running `garage layout assign`
              # manually. Init only ensures peer connections.
              echo "garage-init: peers configured, skipping layout/bucket/key bootstrap"
            ''}
          '';
        };

        # DynamicUser (garage module default) conflicts with bind-mounted /var/lib/garage
        systemd.services.garage.serviceConfig.DynamicUser = lib.mkForce false;

        networking = {
          defaultGateway6 = {
            address = "2001:470:482f::1";
            interface = "eth0";
          };
          nameservers = [ "2001:470:482f::1" ];
          useHostResolvConf = false;
          firewall.enable = false;
        };

        system.stateVersion = "25.05";
      };
    };
  };
}
