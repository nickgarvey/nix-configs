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
          chain input {
            type filter hook input priority 0; policy drop;

            # Connection tracking
            ct state established,related accept
            ct state invalid drop

            # Loopback
            iif lo accept

            # LAN -> router
            iifname "${cfg.lanInterface}" tcp dport { 22 } accept
            iifname "${cfg.lanInterface}" udp dport { 53, 67, 68 } accept
            iifname "${cfg.lanInterface}" tcp dport { 53 } accept
            iifname "${cfg.lanInterface}" udp dport { 546, 547 } accept
            iifname "${cfg.lanInterface}" icmp type echo-request accept
            iifname "${cfg.lanInterface}" icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept

            # WAN -> router: allow protocol 41 (6in4) from HE endpoint
            ${lib.optionalString heCfg.enable ''
              iifname "${cfg.wanInterface}" ip protocol 41 ip saddr ${heCfg.serverIPv4} accept
            ''}

            # TEMPORARY: WAN SSH access during migration from old router. Remove
            # once all devices are on the LAN subnet and WAN is connected to ISP.
            iifname "${cfg.wanInterface}" tcp dport 22 accept

            # WAN -> router: PMTUD and essential ICMP
            iifname "${cfg.wanInterface}" icmp type { destination-unreachable, time-exceeded } accept
            iifname "${cfg.wanInterface}" icmpv6 type { destination-unreachable, packet-too-big, time-exceeded } accept

            # WAN -> router: allow Tailscale
            iifname "${cfg.wanInterface}" udp dport 41641 accept

            # HE tunnel -> router: allow ICMPv6
            ${lib.optionalString heCfg.enable ''
              iifname "he-ipv6" icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
            ''}

            # Reject with proper ICMP
            reject with icmpx admin-prohibited
          }

          chain forward {
            type filter hook forward priority 0; policy drop;

            ct state established,related accept
            ct state invalid drop

            # TCP MSS clamping — prevents MTU black holes, especially with 6in4 tunnel
            tcp flags syn tcp option maxseg size set rt mtu

            # LAN -> WAN: allow all outbound
            iifname "${cfg.lanInterface}" oifname "${cfg.wanInterface}" accept

            # TEMPORARY: Allow old LAN (10.28.0.0/16) to reach new LAN during migration.
            # Remove once old router is decommissioned.
            iifname "${cfg.wanInterface}" oifname "${cfg.lanInterface}" ip saddr 10.28.0.0/16 accept

            # LAN <-> HE tunnel
            ${lib.optionalString heCfg.enable ''
              iifname "${cfg.lanInterface}" oifname "he-ipv6" accept
              iifname "he-ipv6" oifname "${cfg.lanInterface}" icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
            ''}

            # LAN <-> Tailscale
            iifname "tailscale0" oifname "${cfg.lanInterface}" accept
            iifname "${cfg.lanInterface}" oifname "tailscale0" accept
          }
        '';
      };

      nat = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat;

            # TEMPORARY: Don't NAT traffic between new and old LAN during migration.
            # Remove once old router is decommissioned.
            oifname "${cfg.wanInterface}" ip daddr 10.28.0.0/16 accept

            # Masquerade all traffic going out WAN (internet-bound)
            oifname "${cfg.wanInterface}" masquerade
          }
        '';
      };
    };
  };
}
