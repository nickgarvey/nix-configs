{ config, lib, pkgs, ... }:

let
  cfg = config.nspawn.caddy-static;
  wwwPath = cfg.wwwPath;
  siteAddress = cfg.siteAddress;
in
{
  options.nspawn.caddy-static = {
    enable = lib.mkEnableOption "caddy-static nspawn container";

    wwwPath = lib.mkOption {
      type = lib.types.str;
      default = "/www";
      description = "Host path whose contents are served as static files.";
    };

    siteAddress = lib.mkOption {
      type = lib.types.str;
      default = ":8080";
      description = ''
        Caddy site address. Default ":8080" serves plain HTTP on that port.
        Set to a hostname (e.g. "files.example.com") to enable Caddy's
        automatic Let's Encrypt TLS — then also adjust openFirewallPorts
        to [ 80 443 ] so ACME HTTP-01 and HTTPS traffic get through.
      '';
    };

    openFirewallPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 8080 ];
      description = "Host firewall ports to open for caddy.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${wwwPath} 0755 ngarvey users - -"
    ];

    networking.firewall.allowedTCPPorts = cfg.openFirewallPorts;

    containers.caddy-static = {
      autoStart = true;
      privateNetwork = false;

      bindMounts.${wwwPath} = {
        hostPath = wwwPath;
        isReadOnly = true;
      };

      config = { pkgs, lib, ... }: {
        services.caddy = {
          enable = true;
          # `file_server browse` serves index.html when present, otherwise
          # renders a directory listing — so dropping files into /www makes
          # them immediately visible at the site root without any reload.
          virtualHosts.${siteAddress}.extraConfig = ''
            root * ${wwwPath}
            file_server browse
          '';
        };

        networking.firewall.enable = false;

        system.stateVersion = "25.05";
      };
    };
  };
}
