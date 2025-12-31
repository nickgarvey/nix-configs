{ config, lib, pkgs, inputs, ... }:
let
  localStoragePath = "/var/lib/rancher/k3s/storage";
in
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/nixos-common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "framework";

  boot.kernelPackages = pkgs.linuxPackages_latest;
  services.k3s.role = "agent";

  assertions = [{
    assertion = config.fileSystems ? "${localStoragePath}";
    message = "Local storage partition must be mounted at ${localStoragePath}";
  }];
}
