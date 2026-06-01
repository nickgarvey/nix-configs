{ config, lib, ... }:

let
  cfg = config.routerConfig;
  heCfg = cfg.heTunnel;

  inherit (import ../lan-hosts.nix) lanHosts;
  k3sNodes = builtins.filter (h: h.podCIDR or null != null && h.ipv6 != null) lanHosts;
  podRoutes = map (h: { Destination = h.podCIDR; Gateway = h.ipv6; }) k3sNodes;
in
{
  config = lib.mkIf heCfg.enable {
    # IPv6 addressing and RA on the LAN bridge.
    # Depends on heTunnel for the routed prefix, but is conceptually LAN config.
    systemd.network.networks."10-lan" = {
      address = [
        # Router's address on the main LAN (:0 subnet).
        # Use /64 so the router knows subnet :0 is on-link.
        "${heCfg.routedPrefix}1/64"
        # NOTE: the router deliberately does NOT claim an address inside
        # the LB /112 (2001:470:482f:2::/112). LAN hosts install an ECMP
        # /112 route to that prefix via the k3s nodes (Cilium L2-announce
        # targets); a router-side address in the same /112 would be
        # shadowed by that ECMP and break reply paths. The LB subnet is
        # made on-link for the router via the interface route below.
        #
        # Router-side container delegated /64. Mirrors lydia (200::/64)
        # and talos (201::/64): the router's bridge address acts as
        # the /48 next-hop for nspawn containers running on the router
        # (storj-gateway, trmnl-proxy, …).
        "2001:470:482f:300::1/64"
      ];
      networkConfig.IPv6SendRA = true;
      ipv6SendRAConfig = {
        Managed = false;        # SLAAC
        OtherInformation = true; # Clients query DHCPv6 for DNS info
        # Advertise only the main LAN /64 for SLAAC — NOT the full /48.
        # Don't install this router as default IPv6 gateway.
        # HE tunnel broker prefixes are frequently flagged by Google et al.
        RouterLifetimeSec = 0;
      };
      ipv6Prefixes = [
        { Prefix = "2001:470:482f::/64"; }     # Main LAN SLAAC
        # Do NOT advertise :2::/64 — LB IPs use Cilium L2 NDP announcements.
        # Advertising this prefix gives LAN hosts SLAAC addresses in :2::,
        # which breaks source address selection for LB destinations.
      ];
      # Advertise a route for the whole homelab /48 via RA so LAN clients
      # learn to reach any delegated /64 (k3s pods, per-host delegations,
      # future allocations) through the router. Longest-prefix-match keeps
      # LAN-/64 and pod-CIDR static routes preferred where they exist.
      # Lifetime 0 on the default route (RouterLifetimeSec above) means
      # this is NOT a default IPv6 gateway.
      ipv6RoutePrefixes = [
        { Route = "2001:470:482f::/48"; LifetimeSec = 3600; }
      ];
      # Kernel routes:
      #   - podRoutes (one /64 per k3s node) — return traffic from HE
      #     tunnel reaches the correct k3s node.
      #   - Per-host delegated /64s (lydia, talos) — on-link on
      #     br-lan; NDP resolves to the host's vmbr0.
      routes = podRoutes ++ [
        { Destination = "2001:470:482f:200::/64"; }  # lydia delegated /64
        { Destination = "2001:470:482f:201::/64"; }  # talos delegated /64
        # 300::/64 is on-link via the router's own address above; no
        # explicit route needed here (kernel installs it from the addr).
        # Cilium LB pool — on-link via br-lan so the router can
        # NDP-resolve LB IPs (announced from any k3s node via Cilium L2)
        # when forwarding from HE / Tailscale / WAN. Deliberately a
        # route, not an address: an address would shadow LAN hosts'
        # ECMP /112 for this prefix. See address block above.
        { Destination = "2001:470:482f:2::/112"; }
      ];
    };
  };
}
