{ config, lib, pkgs, inputs, ... }:
# Framework Desktop (AMD Ryzen AI MAX+ 395) running headless as a server.
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/networkd.nix
  ];

  networking.hostName = "wabbajack";
  homelab.network.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Pinned so /home ownership stays stable across reinstalls.
  users.users.ngarvey.uid = 1000;

  system.stateVersion = "25.11";
}
