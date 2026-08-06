{ config, lib, pkgs, ... }:

# Recursive resolver sitting BEHIND blocky (see blocky-dns.nix).
#
# Blocky is a forwarder, not a resolver: it never iterates from the root, and it
# only chases CNAMEs that come from its own customDNS -- CNAMEs from an upstream
# are returned verbatim. That breaks cross-zone aliases like
# zot.home.garvey.sh -> zot.zot.k8s.home.garvey.sh, where Knot (authoritative for
# the parent only) answers with a CNAME plus a referral. Clients whose stub
# resolver doesn't re-query -- musl/Alpine, notably -- fail outright.
#
# So blocky keeps doing what it is good at (blocklists, DNS64, customDNS, client
# groups) and delegates *resolution* to kresd, which recurses from the root and
# chases CNAMEs natively. Complete answers then flow back through blocky.
#
# Listens on loopback only: blocky owns :53 on every interface, and nothing but
# blocky ever talks to this.

let
  # Authoritative servers for our own zones. Declared here rather than as blocky
  # conditional mappings on purpose -- routing them through kresd is what makes
  # CNAME chasing work. Most specific subtree first.
  stubs = [
    { subtree = "k8s.home.garvey.sh"; servers = [ "2001:470:482f:2::53" ]; }  # k8s_gateway
    { subtree = "home.garvey.sh";     servers = [ "10.28.0.6" ]; }            # Knot
    # acme-dns, which holds the _acme-challenge TXT records for DNS-01 (see
    # modules/containers/public-dns-proxy.nix). Cloudflare delegates
    # acme.garvey.sh to itself with glue A 64.186.8.205 -- our own WAN address.
    # That delegation is correct for the public internet (Let's Encrypt hits the
    # WAN, where nftables DNATs :53 to dnsdist), but it is a dead end from the
    # inside: the DNAT rule matches `iifname enp4s0`, so a locally-originated or
    # LAN query to 64.186.8.205:53 is never translated and instead lands on
    # blocky, which forwards it straight back here -- kresd resolving through
    # itself, reported as "No Reachable Authority" (EDE 22). Pointing the subtree
    # at the acme-dns LoadBalancer directly sidesteps the hairpin. Without this,
    # cert-manager's DNS-01 self-check (cluster -> blocky -> kresd) hangs at
    # "Waiting for DNS-01 challenge propagation" and no cert is ever issued.
    { subtree = "acme.garvey.sh";     servers = [ "2001:470:482f:2::5300" ]; } # acme-dns
  ];

  mkStub = s: {
    inherit (s) subtree servers;
    options = {
      # These targets are authoritative servers, not recursive resolvers, so
      # kresd must drive resolution itself rather than expecting a full answer.
      authoritative = true;
      # home.garvey.sh is unsigned and has no DS record, so validation would
      # SERVFAIL the whole zone. Revisit only if the zone is ever signed.
      dnssec = false;
    };
  };
in
{
  services.knot-resolver = {
    enable = true;
    settings = {
      network.listen = [
        {
          interface = [ "127.0.0.1" ];
          port = 5353;
          kind = "dns";
        }
      ];

      # No `forward` for the root: recursing from the root servers is the whole
      # point, and it is kresd's default behaviour.
      forward = map mkStub stubs;
    };
  };

  # The upstream unit ships Restart=no. kresd 6's internal supervisord already
  # restarts a crashed *worker* (autorestart=true), but nothing recovers the
  # supervisor itself -- and if it dies, blocky loses its only upstream and
  # every public name SERVFAILs until someone intervenes by hand. (LAN names
  # survive: those come from blocky's own customDNS and conditional mappings.)
  #
  # Type=notify means systemd waits for readiness on each restart, so blocky's
  # After=knot-resolver.service ordering still holds. The unit's existing
  # StartLimitBurst=5 / 10s caps a crash loop, so a genuinely broken config
  # still fails hard instead of spinning.
  systemd.services.knot-resolver.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "2s";
  };
}
