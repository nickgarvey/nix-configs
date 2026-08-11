{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/router
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/containers/trmnl-proxy.nix
    ../../modules/containers/storj-gateway.nix
    ../../modules/containers/unifi.nix
    ../../modules/containers/public-dns-proxy.nix
    ../../modules/containers/knot-auth.nix
  ];

  networking.hostName = "dragonsreach";

  # mongodb (unifi dependency) fails to build on current nixpkgs pin —
  # cheetah3 metadata check breaks under python 3.14. Re-enable once a
  # flake update picks up the upstream fix. The DNS record and DHCP option 43
  # that pointed clients at the controller were removed while it is down;
  # modules/containers/unifi.nix documents everything needed to restore them.
  homelab.unifi.enable = false;

  services.icmpv6-archive = {
    enable = true;
    interface = "br-lan";
  };

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

  sops.defaultSopsFile = ../../secrets/dragonsreach.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "25.05";
}
