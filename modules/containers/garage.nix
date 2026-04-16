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
            replication_factor = 1;

            rpc_bind_addr = "[::]:3901";

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

            CURRENT_VERSION=$(garage layout show | awk '/Current cluster layout version:/ {print $NF}')

            if garage layout show | grep -q "No nodes currently have a role"; then
              garage layout assign -z dc1 -c 500G "$NODE_ID"
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
