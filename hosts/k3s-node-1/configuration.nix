{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/nixos-common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "k3s-node-1";
  k3sConfig.isFirstNode = true;
  homelab.network.podCIDR = "2001:470:482f:100::/64";

  # Prevent unused secondary NIC from being created
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="78:55:36:00:4c:c5", ATTR{device/driver/unbind}="0000:02:00.0"
  '';
}
