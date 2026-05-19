{ config, lib, pkgs, ... }:

# Storj single-tenant S3 gateway (libuplink-backed). Runs inside a
# systemd-nspawn container on the router's "router-side container" /64
# (2001:470:482f:300::/64). Dual-stack: libuplink needs native IPv4 to
# reach Storj storagenodes (predominantly v4); k3s pods reach the
# gateway over IPv6 via storj-gateway.home.arpa.
#
# The access grant holds the encryption passphrase, so encryption
# happens here on the router before pieces are uploaded to the Storj
# satellites. Storj never sees plaintext.

let
  storjGatewayPkg = pkgs.callPackage ../../pkgs/storj-gateway-st { };
in
{
  imports = [ ./common.nix ];

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
