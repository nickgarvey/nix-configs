{ config, lib, pkgs, ... }:

{
  config = {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      extraUpFlags = [
        "--accept-dns=false"
      ];
      extraSetFlags = [
        "--advertise-exit-node"
        "--advertise-routes=2001:470:482f::/48"
        "--accept-dns=false"
      ];
    };
  };
}
