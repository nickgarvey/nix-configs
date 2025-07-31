{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/nixos-common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "k3s-node-1";
  services.k3s.clusterInit = true;
}
