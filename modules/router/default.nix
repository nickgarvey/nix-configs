{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
in
{
  imports = [
    ./nftables.nix
    ./kea-dhcp.nix
    ./blocky-dns.nix
    ./he-tunnel.nix
    ./tailscale.nix
  ];

  options.routerConfig = {
    wanInterface = lib.mkOption {
      type = lib.types.str;
      description = "Network interface connected to the ISP/WAN.";
    };

    lanInterface = lib.mkOption {
      type = lib.types.str;
      description = "Network interface connected to the LAN.";
    };

    lanAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.28.0.1";
      description = "Router's IPv4 address on the LAN.";
    };

    lanPrefixLength = lib.mkOption {
      type = lib.types.int;
      default = 16;
      description = "LAN subnet prefix length.";
    };

    lanSubnet = lib.mkOption {
      type = lib.types.str;
      default = "10.28.0.0/16";
      description = "LAN subnet in CIDR notation.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "home.arpa";
      description = "Local domain name.";
    };
  };

  config = {
    # Disable NetworkManager; use systemd-networkd for a router
    networking.networkmanager.enable = false;
    systemd.network.enable = true;
    networking.useNetworkd = true;

    # Disable the default NixOS iptables firewall; we use nftables
    networking.firewall.enable = false;
    networking.nftables.enable = true;

    # IP forwarding
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    # WAN interface — DHCP from ISP
    systemd.network.networks."20-wan" = {
      matchConfig.Name = cfg.wanInterface;
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.UseDNS = false; # We run our own DNS
    };

    # LAN interface — static address
    systemd.network.networks."10-lan" = {
      matchConfig.Name = cfg.lanInterface;
      address = [
        "${cfg.lanAddress}/${toString cfg.lanPrefixLength}"
      ];
      networkConfig = {
        DHCPServer = false; # kea handles DHCP
      };
    };
  };
}
