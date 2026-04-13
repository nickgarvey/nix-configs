{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/router
    ../../modules/containers/unifi.nix
    ../../modules/containers/trmnl-proxy.nix
  ];

  networking.hostName = "router";

  routerConfig = {
    wanInterface = "enp4s0";
    wanMacAddress = "20:6d:31:ee:38:09";
    lanInterfaces = [ "enp1s0" "enp2s0" "enp3s0" ];

    heTunnel = {
      enable = true;
      serverIPv4 = "64.62.134.130";
      clientIPv6 = "2001:470:66:35::2/64";
      serverIPv6 = "2001:470:66:35::1";
      routedPrefix = "2001:470:482f::";
      routedPrefixLength = 64;
    };
  };

  environment.systemPackages = with pkgs; [
    conntrack-tools
    ethtool
    iperf3
    tcpdump
  ];

  sops.defaultSopsFile = ../../secrets/router.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "25.05";
}
