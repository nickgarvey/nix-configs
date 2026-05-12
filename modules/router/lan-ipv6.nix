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
        # k8s LB subnet (:2::/112) — router needs an address for return routing
        # from HE tunnel, but use /112 to match the actual LB pool size.
        "2001:470:482f:2::1/112"
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
      #   - Per-host delegated /64s (aboleth, tarrasque) — on-link on
      #     br-lan; NDP resolves to the host's vmbr0.
      routes = podRoutes ++ [
        { Destination = "2001:470:482f:200::/64"; }  # aboleth delegated /64
        { Destination = "2001:470:482f:201::/64"; }  # tarrasque delegated /64
      ];
    };
  };
}
