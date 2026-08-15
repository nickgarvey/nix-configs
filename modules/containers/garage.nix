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

      };
    };
  };
}
