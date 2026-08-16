{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/k3s/k3s-common.nix
    ../../modules/k3s/kata.nix
    ../../modules/core/nixos-common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "ro";

  # Prevent unused secondary NIC from being created
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="78:55:36:00:47:f3", ATTR{device/driver/unbind}="0000:02:00.0"
  '';
}
