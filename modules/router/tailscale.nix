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
        "--accept-dns=false"
      ];
    };
  };
}
