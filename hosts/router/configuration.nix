{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/router
  ];

  networking.hostName = "router";

  # TEMPORARY: Allow console login during migration. Remove once stable.
  users.users.root.initialHashedPassword = "";

  routerConfig = {
    wanInterface = "enp4s0";
    lanInterface = "enp1s0";
    lanAddress = "10.29.0.1";
    lanSubnet = "10.29.0.0/16";
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
