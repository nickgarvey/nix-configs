{ config, lib, pkgs, ... }:

# Public :53 front door for every zone we serve authoritatively, and the bridge
# from the stable public IPv4 to IPv6-only backends.
#
# There is one public IPv4 and one port 53, but three authoritative backends —
# and none can proxy for the others (Knot and acme-dns are authoritative-only and
# cannot forward). So dnsdist splits inbound queries by qname:
#
#   acme.garvey.sh.     -> acme-dns     [2001:470:482f:2::5300]  (Let's Encrypt)
#   k8s.home.garvey.sh. -> k8s_gateway  [2001:470:482f:2::53]
#   home.garvey.sh.     -> Knot         10.28.0.6
#
# Blocky owns :53 on the router host (all interfaces), so the relay can't live
# on the host directly — it runs in a dedicated nspawn container with its own
# LAN IPv4, mirroring trmnl-proxy. The router DNATs WAN:53 -> 10.28.0.5:53
# (see modules/router/nftables.nix).

{
  imports = [ ./common.nix ];

  nspawn.network.public-dns-proxy = {
    attachment = "bridge";
    hostBridge = "br-lan";
    localAddress = "10.28.0.5/16";
    ipv4Gateway = "10.28.0.1";
    ipv4Nameservers = [ "10.28.0.1" ];
    # Replies go to public Let's Encrypt IPs (not just the LAN), so the
    # container needs a real IPv4 default route, unlike trmnl-proxy.
    ipv4DefaultRoute = true;
    # IPv6 on br-lan so dnsdist can reach the LB pool. common.nix installs a
    # 2001:470:482f::/48 route via hostBridgeAddress; the router then forwards
    # to the Cilium-announced LB IP (existing forward rule, nftables.nix:124).
    localAddress6 = "2001:470:482f::5300/64";
    hostBridgeAddress = "2001:470:482f::1";
  };

  containers.public-dns-proxy = {
    config = { config, pkgs, ... }: {
      services.dnsdist = {
        enable = true;
        listenAddress = "10.28.0.5";
        listenPort = 53;
        extraConfig = ''
          -- This is a PUBLIC authoritative endpoint (Let's Encrypt resolves the
          -- acme.garvey.sh delegation here from arbitrary internet IPs). dnsdist's
          -- default ACL only allows RFC1918/local ranges, so it would silently
          -- drop UDP / RESET TCP from public resolvers. Open it to all — the
          -- backend (acme-dns) is authoritative-only and never recurses, so this
          -- can't be abused as an open resolver.
          setACL({"0.0.0.0/0", "::/0"})

          -- Every backend is authoritative-only, so the default health check
          -- (recursive "A a.root-servers.net") would be REFUSED and mark it down.
          -- Check each one's own apex instead, as SOA: all three answer SOA
          -- there, whereas an A query at the apex returns NODATA.
          -- source= pins the outgoing address for the IPv6 backends. Without it
          -- the kernel picks one at socket-creation time, and if dnsdist starts
          -- before eth0's static GUA and the /48 route are in place it binds the
          -- LINK-LOCAL address instead -- and keeps it for the process lifetime.
          -- Queries then leave from fe80::… , the backend's replies are
          -- unroutable, and every forwarded query silently times out.
          --
          -- This is invisible to monitoring: health checks use fresh sockets, so
          -- they pick the GUA, succeed, and report the backend UP the whole time
          -- while every forwarded query is black-holed. Pinning the source makes
          -- a too-early start fail LOUDLY (bind error + Restart) instead.
          newServer({address="[2001:470:482f:2::5300]:53", pool="acmedns",
                     source="2001:470:482f::5300",
                     checkName="acme.garvey.sh.", checkType="SOA"})
          newServer({address="[2001:470:482f:2::53]:53", pool="k8sgw",
                     source="2001:470:482f::5300",
                     checkName="k8s.home.garvey.sh.", checkType="SOA"})
          newServer({address="10.28.0.6:53", pool="knot",
                     checkName="home.garvey.sh.", checkType="SOA"})

          -- Route by qname suffix. Rules are evaluated in order, so the more
          -- specific k8s subzone MUST come before its parent -- otherwise k8s
          -- queries land on Knot, which only holds a delegation back to this
          -- same IP, and the resolver loops.
          addAction("acme.garvey.sh.", PoolAction("acmedns"))
          addAction("k8s.home.garvey.sh.", PoolAction("k8sgw"))
          addAction("home.garvey.sh.", PoolAction("knot"))

          -- Anything else gets REFUSED rather than reaching a backend. Without
          -- this, a query for an unrouted name falls through to the default pool
          -- (empty) and, more importantly, nothing here should ever look like an
          -- open resolver to the internet.
          addAction(AllRule(), RCodeAction(DNSRCode.REFUSED))
        '';
      };

      # dnsdist ships no ordering against the network units, so it can create its
      # backend sockets before eth0 has its static IPv6 address and the /48
      # intra-site route (installed by nspawn-intrasite-route6 in common.nix).
      # Combined with the pinned source= above, a too-early start now fails to
      # bind and gets retried rather than running on a bad socket forever.
      systemd.services.dnsdist = {
        after = [ "network-addresses-eth0.service" "nspawn-intrasite-route6.service" ];
        wants = [ "network-addresses-eth0.service" "nspawn-intrasite-route6.service" ];
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };

      system.stateVersion = "25.05";
    };
  };
}
