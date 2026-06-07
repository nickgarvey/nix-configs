{ config, lib, ... }:

let
  cfg = config.homelab.network;

  inherit (import ./lan-hosts.nix) lanHosts;
  hostname = config.networking.hostName;
  hostEntry = lib.findFirst (h: h.hostname == hostname) null lanHosts;

  hasBridge = cfg.bridge != null;
  hasMac = hostEntry != null && hostEntry.mac != "";
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
          ipv6.suppressSlaac = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Suppress SLAAC address autoconfiguration on this bridge while
              still using RA-derived on-link prefix and route information.
              Set true for hosts whose static IPv6 is outside the LAN /64
              (e.g. in a delegated per-host prefix).
            '';
          };
        };
      });
      default = null;
      description = "Bridge with static IPv4. IPv6 is auto-added from lan-hosts.nix if available.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      networking.useNetworkd = true;
    }

    (lib.mkIf cfg.ipv4Forward {
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    })

    (lib.mkIf cfg.ipv6Forward {
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    })

    # IPv6-only host: static IPv6 from lan-hosts.nix, no IPv4, default
    # gateway via router.
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

    # Dual-stack host without a bridge: IPv4 via DHCP, static IPv6 from
    # lan-hosts.nix.
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

    (lib.mkIf hasBridge (let br = cfg.bridge; in {
      systemd.network.netdevs."10-${br.name}" = {
        netdevConfig = {
          Name = br.name;
          Kind = "bridge";
        };
        # STP is off; without this, ports still sit in listening/learning for
        # 15s, dropping the boot-time IPv6 RS so the LAN /64 RA route is missed.
        bridgeConfig = {
          STP = false;
          ForwardDelaySec = 0;
        };
      };

      # Match by MAC when we know it (from lan-hosts.nix) so the bridge slave
      # survives PCI renumbering when other cards are added/removed.
      systemd.network.networks."10-${br.interface}" = {
        matchConfig = if hasMac
          then { MACAddress = hostEntry.mac; }
          else { Name = br.interface; };
        networkConfig.Bridge = br.name;
      };

      systemd.network.networks."10-${br.name}" = {
        matchConfig.Name = br.name;
        address = [ br.ipv4.address ]
          ++ lib.optionals hasIPv6 [ "${hostEntry.ipv6}/64" ];
        gateway = [ br.ipv4.gateway ];
        dns = br.ipv4.dns ++ [ "2001:470:482f::1" ];
        networkConfig = {
          DHCP = "no";
          # networkd defaults IPv6AcceptRA off when IPv6 forwarding is on.
          IPv6AcceptRA = true;
        };
        ipv6AcceptRAConfig = lib.mkIf br.ipv6.suppressSlaac {
          UseAutonomousPrefix = false;
        };
        routes = lib.optionals (hasIPv6 && !isK3sNode) (podRoutes ++ lbRoutes);
      };

      networking.firewall.trustedInterfaces = [ br.name ];

      # br_netfilter (loaded by Incus on lydia) would route bridge frames
      # through ip/ip6/arp tables, breaking DHCP and host connectivity on
      # vmbr0. Force-off so the bridge stays a pure L2 path.
      boot.kernel.sysctl = {
        "net.bridge.bridge-nf-call-iptables" = 0;
        "net.bridge.bridge-nf-call-ip6tables" = 0;
        "net.bridge.bridge-nf-call-arptables" = 0;

        # Host's delegated /64 is reached via on-link NDP, so a uplink flap
        # (igc resets link ~1min into boot) leaves the router with a stale
        # neighbor entry and blackholes inbound IPv6 to the host until NUD
        # re-resolves. ndisc_notify emits an unsolicited NA on link-up so the
        # router refreshes immediately; arp_notify is the IPv4 analog. Set via
        # `default` (inherited by the networkd-created bridge), not per-iface.
        "net.ipv6.conf.all.ndisc_notify" = 1;
        "net.ipv6.conf.default.ndisc_notify" = 1;
        "net.ipv4.conf.all.arp_notify" = 1;
        "net.ipv4.conf.default.arp_notify" = 1;
      };
    }))
  ]);
}
