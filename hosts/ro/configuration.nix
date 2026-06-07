{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/k3s/k3s-common.nix
    ../../modules/core/nixos-common.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "ro";
  homelab.network.podCIDR = "2001:470:482f:101::/64";

  services.icmpv6-archive.enable = true;

  # Prevent unused secondary NIC from being created
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="78:55:36:00:47:f3", ATTR{device/driver/unbind}="0000:02:00.0"
  '';
}
