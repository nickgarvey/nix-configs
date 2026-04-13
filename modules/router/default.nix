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
    ./nat64.nix
    ./tailscale.nix
  ];

  options.routerConfig = {
    wanInterface = lib.mkOption {
      type = lib.types.str;
      description = "Network interface connected to the ISP/WAN.";
    };

    wanMacAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "MAC address to spoof on the WAN interface. Empty string uses the hardware MAC.";
    };

    lanInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Physical network interfaces to bridge into the LAN.";
    };

    lanInterface = lib.mkOption {
      type = lib.types.str;
      default = "br-lan";
      description = "Name of the LAN bridge interface.";
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

    # IP forwarding + anti-spoofing
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.ipv6.conf.${cfg.wanInterface}.accept_ra" = 2; # accept RA even with forwarding enabled
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.conf.tailscale0.rp_filter" = 2; # loose — Tailscale source IPs don't match routing table
    };

    # WAN interface — DHCP from ISP
    systemd.network.networks."20-wan" = {
      matchConfig.Name = cfg.wanInterface;
      linkConfig = lib.mkIf (cfg.wanMacAddress != "") {
        MACAddress = cfg.wanMacAddress;
      };
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.UseDNS = false; # We run our own DNS
    };

    # LAN bridge device
    systemd.network.netdevs."10-br-lan" = {
      netdevConfig = {
        Name = cfg.lanInterface;
        Kind = "bridge";
      };
    };

    # Bind physical LAN ports to the bridge
    systemd.network.networks."10-lan-members" = {
      matchConfig.Name = builtins.concatStringsSep " " cfg.lanInterfaces;
      networkConfig.Bridge = cfg.lanInterface;
    };

    # LAN bridge — static address
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
