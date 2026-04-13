{ config, lib, pkgs, ... }:

# L7 reverse proxy for the TRMNL e-ink display.
#
# The TRMNL device is IPv4-only but trmnl-display runs on the IPv6-only
# k3s cluster. This nginx container bridges the gap: listens on a
# dedicated LAN IPv4 and proxies to the IPv6 LoadBalancer IP.
#
# Uses host networking (like the unifi container) to avoid bridge/NDP
# issues with private networking.

let
  cfg = config.routerConfig;
in
{
  # Add a secondary IPv4 to br-lan for the proxy
  systemd.network.networks."10-lan".address = lib.mkAfter [
    "10.28.0.2/16"
  ];

  containers.trmnl-proxy = {
    autoStart = true;
    privateNetwork = false; # host networking

    config = { config, pkgs, ... }: {
      services.nginx = {
        enable = true;
        virtualHosts."trmnl-proxy" = {
          listen = [
            { addr = "10.28.0.2"; port = 80; }
          ];
          locations."/" = {
            proxyPass = "http://[2001:470:482f:2::5]:80";
          };
        };
      };

      system.stateVersion = "25.05";
    };
  };
}
