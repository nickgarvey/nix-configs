{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/nixos-common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "k3s-node-3";
  homelab.network.podCIDR = "2001:470:482f:102::/64";

  # Prevent unused secondary NIC from being created
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="78:55:36:00:4d:81", ATTR{device/driver/unbind}="0000:02:00.0"
  '';
}
