{ config, lib, pkgs, ... }:

# Storj single-tenant S3 gateway (libuplink-backed). Runs inside a
# systemd-nspawn container using host networking so libuplink has direct
# dual-stack access — Storj storagenodes are predominantly IPv4 and
# unreachable from the IPv6-only k3s cluster.
#
# Cluster pods reach this gateway on the router's LAN IPv6, port 7777.
# Inbound is firewalled to the cluster pod CIDR only (see
# modules/router/nftables.nix).
#
# The access grant holds the encryption passphrase, so encryption happens
# here on the router before pieces are uploaded to the Storj satellites.
# Storj never sees plaintext.

let
  storjGatewayPkg = pkgs.callPackage ../../pkgs/storj-gateway-st { };
in
{
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
    autoStart = true;
    privateNetwork = false; # host networking — needs native IPv4 to reach storagenodes

    bindMounts = {
      "/run/storj-gateway.env" = {
        hostPath = config.sops.templates."storj-gateway.env".path;
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

      networking.firewall.enable = false;

      system.stateVersion = "25.05";
    };
  };
}
