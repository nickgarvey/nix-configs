{ config, lib, ... }:

let
  cfg = config.homelab.network;

  inherit (import ./lan-hosts.nix) lanHosts;
  hostname = config.networking.hostName;
  hostEntry = lib.findFirst (h: h.hostname == hostname) null lanHosts;

  hasBridge = cfg.bridge != null;
  hasIPv6 = hostEntry != null && hostEntry.ipv6 != null && hostEntry.mac != "";

  # Static routes for k3s pod CIDRs — each k3s node gets a /64 from the /56 pod range.
  # Non-k3s hosts need these routes so pods can communicate with LAN services (return path).
  k3sNodes = builtins.filter (h: h.podCIDR or null != null && h.ipv6 != null) lanHosts;
  isK3sNode = lib.any (h: h.hostname == hostname) k3sNodes;
  podRoutes = map (h: {
    Destination = h.podCIDR;
    Gateway = h.ipv6;
  }) k3sNodes;

  # ECMP routes for k8s LoadBalancer subnet — Cilium L2 announces LB IPs from
  # any node, so spread traffic across all k3s nodes.
  lbRoutes = map (h: {
    Destination = "2001:470:482f:2::/112";
    Gateway = h.ipv6;
  }) k3sNodes;
in
{
  options.homelab.network = {
    enable = lib.mkEnableOption "homelab network configuration";

    ipv6Only = lib.mkEnableOption "IPv6-only networking (no IPv4, static IPv6 from lan-hosts.nix)";

    ipv4Forward = lib.mkEnableOption "IPv4 forwarding";
    ipv6Forward = lib.mkEnableOption "IPv6 forwarding";

    podCIDR = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Pod CIDR (/64) assigned to this node for k3s pod networking.";
    };

    bridge = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Bridge device name.";
          };
          interface = lib.mkOption {
            type = lib.types.str;
            description = "Physical interface to enslave to the bridge.";
          };
          ipv4 = {
            address = lib.mkOption {
              type = lib.types.str;
              description = "Static IPv4 address in CIDR notation (e.g. \"10.28.12.108/16\").";
            };
            gateway = lib.mkOption {
              type = lib.types.str;
              description = "IPv4 default gateway (e.g. \"10.28.0.1\").";
            };
            dns = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "10.28.0.1" ];
              description = "IPv4 DNS servers.";
            };
          };
          # IPv6 is auto-derived from lan-hosts.nix and added to the bridge if available
        };
      });
      default = null;
      description = "Bridge with static IPv4. IPv6 is auto-added from lan-hosts.nix if available.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # --- Base: always systemd-networkd ---
    {
      networking.useNetworkd = true;
    }

    # --- IPv4 forwarding ---
    (lib.mkIf cfg.ipv4Forward {
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    })

    # --- IPv6 forwarding ---
    (lib.mkIf cfg.ipv6Forward {
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    })

    # --- IPv6-only: static IPv6 address, no IPv4, gateway via router ---
    (lib.mkIf (cfg.ipv6Only && hasIPv6) {
      systemd.network.networks."25-static" = {
        matchConfig.MACAddress = hostEntry.mac;
        networkConfig = {
          DHCP = "no";
        };
        address = [ "${hostEntry.ipv6}/64" ];
        gateway = [ "2001:470:482f::1" ];
        dns = [ "2001:470:482f::1" ];
        routes = lib.optionals (!isK3sNode) (podRoutes ++ lbRoutes);
      };
    })

    # --- Dual-stack: IPv4 via DHCP + static IPv6 (no bridge) ---
    (lib.mkIf (!cfg.ipv6Only && !hasBridge && hasIPv6) {
      systemd.network.networks."25-static" = {
        matchConfig.MACAddress = hostEntry.mac;
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.ClientIdentifier = "mac";
        address = [ "${hostEntry.ipv6}/64" ];
        dns = [ "2001:470:482f::1" ];
        routes = lib.optionals (!isK3sNode) (podRoutes ++ lbRoutes);
      };
    })

    # --- Bridge ---
    (lib.mkIf hasBridge (let br = cfg.bridge; in {
      systemd.network.netdevs."10-${br.name}" = {
        netdevConfig = {
          Name = br.name;
          Kind = "bridge";
        };
      };

      systemd.network.networks."10-${br.interface}" = {
        matchConfig.Name = br.interface;
        networkConfig.Bridge = br.name;
      };

      systemd.network.networks."10-${br.name}" = {
        matchConfig.Name = br.name;
        address = [ br.ipv4.address ]
          ++ lib.optionals hasIPv6 [ "${hostEntry.ipv6}/64" ];
        gateway = [ br.ipv4.gateway ];
        dns = br.ipv4.dns ++ [ "2001:470:482f::1" ];
        networkConfig.DHCP = "no";
        routes = lib.optionals (hasIPv6 && !isK3sNode) (podRoutes ++ lbRoutes);
      };
    }))
  ]);
}
