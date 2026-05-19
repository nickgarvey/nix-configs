{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  heCfg = config.routerConfig.heTunnel;
in
{
  config = {
    networking.nftables.tables = {
      filter = {
        family = "inet";
        content = ''
          set bogons_v4 {
            type ipv4_addr
            flags interval
            elements = {
              0.0.0.0/8,
              10.0.0.0/8,
              100.64.0.0/10,
              127.0.0.0/8,
              169.254.0.0/16,
              172.16.0.0/12,
              192.0.0.0/24,
              192.0.2.0/24,
              192.168.0.0/16,
              198.18.0.0/15,
              198.51.100.0/24,
              203.0.113.0/24,
              224.0.0.0/4,
              240.0.0.0/4
            }
          }

          chain input {
            type filter hook input priority 0; policy drop;

            # ICMPv6 NDP must be accepted before conntrack — conntrack may
            # classify unsolicited NS/NA as "invalid" and drop them.
            icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept

            # Connection tracking
            ct state established,related accept
            ct state invalid drop

            # Loopback
            iif lo accept

            # Tailscale -> router: trust the overlay network
            iifname "tailscale0" accept

            # Bogon filtering on WAN ingress
            iifname "${cfg.wanInterface}" ip saddr @bogons_v4 drop

            # LAN -> router
            iifname "${cfg.lanInterface}" tcp dport { 22 } accept
            iifname "${cfg.lanInterface}" udp dport { 53, 67, 68 } accept
            iifname "${cfg.lanInterface}" tcp dport { 53 } accept

            # TRMNL reverse proxy (nspawn container, host networking)
            iifname "${cfg.lanInterface}" tcp dport { 80 } ip daddr 10.28.0.2 accept

            # NOTE: storj-gateway listener now lives in an nspawn container
            # at 2001:470:482f:300::2; traffic destined for it is handled
            # by the forward chain (pod-CIDR sources permitted via the
            # general LAN→LAN pod-src rule below), not input.

            iifname "${cfg.lanInterface}" udp dport { 546, 547 } accept
            iifname "${cfg.lanInterface}" icmp type echo-request accept
            iifname "${cfg.lanInterface}" icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept

            # WAN -> router: allow protocol 41 (6in4) from HE endpoint
            ${lib.optionalString heCfg.enable ''
              iifname "${cfg.wanInterface}" ip protocol 41 ip saddr ${heCfg.serverIPv4} accept
            ''}

            # WAN -> router: ICMP (ping + PMTUD essentials)
            iifname "${cfg.wanInterface}" icmp type { echo-request, destination-unreachable, time-exceeded } accept
            iifname "${cfg.wanInterface}" icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded } accept

            # WAN -> router: allow Tailscale (rate limited)
            iifname "${cfg.wanInterface}" udp dport 41641 limit rate 50/second accept

            # HE tunnel -> router: allow ICMPv6
            ${lib.optionalString heCfg.enable ''
              iifname "he-ipv6" icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
            ''}

            # Log and reject everything else
            log prefix "nft-input-reject: " limit rate 5/minute
            reject with icmpx admin-prohibited
          }

          chain forward {
            type filter hook forward priority 0; policy drop;

            # Block all outbound forwarded traffic from the LG TV (IPv4 + IPv6)
            iifname "${cfg.lanInterface}" ether saddr ac:5a:f0:2c:ef:18 drop

            # Block all outbound forwarded traffic from the Reolink camera
            iifname "${cfg.lanInterface}" ether saddr c4:3c:b0:f9:df:19 drop

            # LAN <-> LAN: k8s pod traffic must be accepted before conntrack —
            # outbound goes directly node→LAN (on-link), so the router only
            # sees the return path.  Conntrack marks those replies "invalid"
            # (no matching outbound entry) and drops them.
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 daddr 2001:470:482f:100::/56 accept
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 saddr 2001:470:482f:100::/56 accept

            # LAN <-> per-host delegated /64s (aboleth, tarrasque, future).
            # LAN clients (e.g. framework-desktop) don't share a prefix with
            # these hosts, so the router has to forward br-lan→br-lan for
            # both request and reply.
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 daddr 2001:470:482f:200::/56 accept
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 saddr 2001:470:482f:200::/56 accept

            # LAN -> k8s LB pool (:2::/112). Known LAN hosts install ECMP
            # /112 routes via the k3s nodes directly (see lan-network.nix
            # lbRoutes) and never hairpin. Transient clients — laptops,
            # phones, nspawn containers that only learn the /48 via RA —
            # have no more-specific route, so their LB traffic arrives at
            # the router and needs to be forwarded back out br-lan to the
            # k3s node that Cilium L2-announces the LB IP. Reply path is
            # direct k3s-node→client on-link, so only daddr is needed.
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 daddr 2001:470:482f:2::/112 accept

            ct state established,related accept
            ct state invalid drop

            # Bogon filtering on WAN ingress
            iifname "${cfg.wanInterface}" ip saddr @bogons_v4 drop

            # TCP MSS clamping — prevents MTU black holes, especially with 6in4 tunnel
            tcp flags syn tcp option maxseg size set rt mtu

            # Allow forwarding of DNAT'd traffic (port forwards)
            iifname "${cfg.wanInterface}" oifname "${cfg.lanInterface}" ct status dnat accept

            # LAN -> WAN: allow all outbound
            iifname "${cfg.lanInterface}" oifname "${cfg.wanInterface}" accept

            # LAN <-> NAT64 namespace (Jool via jool0 veth)
            iifname "${cfg.lanInterface}" oifname "jool0" accept
            iifname "jool0" oifname "${cfg.wanInterface}" accept
            iifname "jool0" oifname "${cfg.lanInterface}" accept

            # LAN -> HE tunnel: outbound IPv6 from LAN allowed.
            # HE tunnel -> LAN: default-deny. Hosts on the LAN are reachable
            # from the public IPv6 internet by routing, so without this drop
            # every IPv6 listener (including ones with weak/no host firewall,
            # like nspawn containers) would be exposed. Add explicit
            # exposures below as needed. ICMPv6 is allowed for PMTUD / ND.
            ${lib.optionalString heCfg.enable ''
              iifname "${cfg.lanInterface}" oifname "he-ipv6" accept
              iifname "he-ipv6" oifname "${cfg.lanInterface}" meta l4proto ipv6-icmp counter accept
              # (no inbound services currently exposed — anything reaching the
              # final drop below is a denied inbound from the public IPv6
              # internet)
              iifname "he-ipv6" oifname "${cfg.lanInterface}" counter drop
            ''}

            # LAN <-> Tailscale
            iifname "tailscale0" oifname "${cfg.lanInterface}" accept
            iifname "${cfg.lanInterface}" oifname "tailscale0" accept

            # Tailscale exit-node: clients egress to internet via router
            iifname "tailscale0" oifname "${cfg.wanInterface}" accept
            iifname "tailscale0" oifname "jool0" accept

            # Log and drop everything else
            log prefix "nft-forward-drop: " limit rate 5/minute
            drop
          }
        '';
      };

      nat = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat;
          }

          chain postrouting {
            type nat hook postrouting priority srcnat;

            # Hairpin NAT — allows LAN clients to reach port-forwarded services via the WAN IP
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" masquerade

            # Masquerade all traffic going out WAN (internet-bound)
            oifname "${cfg.wanInterface}" masquerade
          }
        '';
      };
    };
  };
}
