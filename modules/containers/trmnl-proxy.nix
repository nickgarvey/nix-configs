{ config, lib, pkgs, ... }:

# L7 reverse proxy for the TRMNL e-ink display.
#
# The TRMNL device is IPv4-only but trmnl-display runs on the IPv6-only
# k3s cluster. This nginx container bridges the gap: listens on a
# dedicated LAN IPv4 and proxies to the IPv6 LoadBalancer IP.

{
  imports = [ ./common.nix ];

  nspawn.network.trmnl-proxy = {
    attachment = "bridge";
    hostBridge = "br-lan";
    localAddress = "10.28.0.2/16";
    ipv4Gateway = "10.28.0.1";
    ipv4Nameservers = [ "10.28.0.1" ];
  };

  containers.trmnl-proxy = {
    config = { config, pkgs, ... }: {
      services.nginx = {
        enable = true;
        virtualHosts."trmnl-proxy" = {
          listen = [
            { addr = "10.28.0.2"; port = 80; }
          ];
          locations."/" = {
            proxyPass = "http://[2001:470:482f:2::5]:80";
            # Preserve client Host header. Without this, nginx defaults
            # Host to the proxy target literal "[2001:470:482f:2::5]:80",
            # and trmnl-display echoes it into image_url — which the
            # IPv4-only ESP32 then cannot dial.
            extraConfig = ''
              proxy_set_header Host $host;
            '';
          };
        };
      };
    };
  };
}
