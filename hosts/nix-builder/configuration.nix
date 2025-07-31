{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/nixos-common.nix
    ./hardware-configuration.nix
  ];

  services.qemuGuest.enable = true;
  boot.loader.grub.enable = true;
  networking.hostName = "nix-builder";
}
