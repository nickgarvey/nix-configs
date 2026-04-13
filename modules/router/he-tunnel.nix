{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  heCfg = cfg.heTunnel;
in
{
  options.routerConfig.heTunnel = {
    enable = lib.mkEnableOption "Hurricane Electric IPv6 tunnel";

    serverIPv4 = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "HE tunnel server IPv4 endpoint (from tunnelbroker.net dashboard).";
    };

    clientIPv6 = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Client IPv6 address for the tunnel endpoint (e.g., 2001:470:xxxx::2/64).";
    };

    serverIPv6 = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Server IPv6 gateway address (e.g., 2001:470:xxxx::1).";
    };

    routedPrefix = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Routed /64 or /48 prefix for LAN clients (e.g., 2001:470:yyyy::/64).";
    };

    routedPrefixLength = lib.mkOption {
      type = lib.types.int;
      default = 64;
      description = "Prefix length of the routed prefix.";
    };
  };

  config = lib.mkIf heCfg.enable {
    # 6in4 SIT tunnel device
    systemd.network.netdevs."he-ipv6" = {
      netdevConfig = {
        Name = "he-ipv6";
        Kind = "sit";
      };
      tunnelConfig = {
        Local = "any";
        Remote = heCfg.serverIPv4;
        TTL = 255;
        Independent = true;
      };
    };

    # Tunnel network configuration
    systemd.network.networks."30-he-ipv6" = {
      matchConfig.Name = "he-ipv6";
      address = [ heCfg.clientIPv6 ];
      routes = [
        { Gateway = heCfg.serverIPv6; Metric = 1024; }
      ];
      networkConfig.IPv6Forwarding = true;
    };

    # Systemd service to update HE tunnel endpoint (for dynamic WAN IP)
    sops.secrets.he-tunnel-credentials = {
      sopsFile = ../../secrets/router.yaml;
    };

    systemd.services.he-tunnel-update = {
      description = "Update Hurricane Electric tunnel endpoint IP";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets.he-tunnel-credentials.path;
        ExecStart = toString (pkgs.writeShellScript "he-tunnel-update" ''
          ${pkgs.curl}/bin/curl -4 --silent --show-error \
            "https://''${HE_USER}:''${HE_PASS}@ipv4.tunnelbroker.net/nic/update?hostname=''${HE_TUNNEL_ID}"
        '');
      };
    };

    systemd.timers.he-tunnel-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
