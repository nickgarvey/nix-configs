{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/router
  ];

  networking.hostName = "router";

  routerConfig = {
    wanInterface = "enp4s0";
    wanMacAddress = "20:6d:31:ee:38:09";
    lanInterfaces = [ "enp1s0" "enp2s0" "enp3s0" ];
    lanInterface = "br-lan";
    lanAddress = "10.28.0.1";
    lanSubnet = "10.28.0.0/16";
    lanPrefixLength = 16;

    # HE tunnel — uncomment and fill in after creating tunnel on tunnelbroker.net:
    # heTunnel = {
    #   enable = true;
    #   serverIPv4 = "";       # e.g., "216.66.xx.xx"
    #   clientIPv6 = "";       # e.g., "2001:470:xxxx::2/64"
    #   serverIPv6 = "";       # e.g., "2001:470:xxxx::1"
    #   routedPrefix = "";     # e.g., "2001:470:yyyy::"
    #   routedPrefixLength = 64;
    # };
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
