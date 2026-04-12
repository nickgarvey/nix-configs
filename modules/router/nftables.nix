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

            # UniFi controller (nspawn container, host networking)
            iifname "${cfg.lanInterface}" tcp dport { 8080, 8443, 8880, 8843, 6789 } accept
            iifname "${cfg.lanInterface}" udp dport { 3478, 10001 } accept

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

            # LAN <-> LAN: k8s pod traffic must be accepted before conntrack —
            # outbound goes directly node→LAN (on-link), so the router only
            # sees the return path.  Conntrack marks those replies "invalid"
            # (no matching outbound entry) and drops them.
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 daddr 2001:470:482f:100::/56 accept
            iifname "${cfg.lanInterface}" oifname "${cfg.lanInterface}" ip6 saddr 2001:470:482f:100::/56 accept

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

            # LAN <-> HE tunnel: fully open in both directions.
            # Clients don't get a default IPv6 route (RouterLifetimeSec=0 in RA)
            # so outbound IPv6 only happens when a host opts in manually.
            ${lib.optionalString heCfg.enable ''
              iifname "${cfg.lanInterface}" oifname "he-ipv6" accept
              iifname "he-ipv6" oifname "${cfg.lanInterface}" ct state new accept
            ''}

            # LAN <-> Tailscale
            iifname "tailscale0" oifname "${cfg.lanInterface}" accept
            iifname "${cfg.lanInterface}" oifname "tailscale0" accept

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

            iifname "${cfg.wanInterface}" tcp dport 443 dnat to 10.28.15.201:443
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
