{ config, lib, pkgs, ... }:

# DNS relay bridging the stable public IPv4 to the IPv6-only k3s cluster so
# Let's Encrypt can reach acme-dns over IPv4.
#
# Blocky owns :53 on the router host (all interfaces), so the relay can't live
# on the host directly — it runs in a dedicated nspawn container with its own
# LAN IPv4, mirroring trmnl-proxy. The router DNATs WAN:53 -> 10.28.0.5:53
# (see modules/router/nftables.nix); dnsdist forwards to the cluster's acme-dns
# DNS LoadBalancer at [2001:470:482f:2::5300]:53.

{
  imports = [ ./common.nix ];

  nspawn.network.acme-dns-proxy = {
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

  containers.acme-dns-proxy = {
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

          -- acme-dns is authoritative-only; the default health check (recursive
          -- "A a.root-servers.net") would be REFUSED and mark the backend down.
          -- Check a name acme-dns actually answers instead.
          newServer({address="[2001:470:482f:2::5300]:53", checkName="acme.garvey.sh."})
        '';
      };

      system.stateVersion = "25.05";
    };
  };
}
