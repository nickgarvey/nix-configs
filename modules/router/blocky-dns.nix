{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ../networking/lan-hosts.nix) lanHosts;
  dns = import ../networking/dns.nix { inherit lib; };

  # lanHosts uses single-string ipv4/ipv6 (one physical host = one IP per family).
  hostIpStr = h:
    if h.ipv4 != null && h.ipv6 != null then "${h.ipv4},${h.ipv6}"
    else if h.ipv6 != null then h.ipv6
    else h.ipv4;

  # dns.records uses list-valued v4/v6, joined for blocky's comma-separated syntax.
  recordIpStr = r: lib.concatStringsSep "," (r.v4 ++ r.v6);

  entries =
    (map (h: { name = h.hostname; value = hostIpStr h; }) lanHosts) ++
    (lib.mapAttrsToList (n: r: { name = n; value = recordIpStr r; }) dns.records);

  dnsMapping = builtins.listToAttrs (
    entries ++
    (map (e: e // { name = "${e.name}.${cfg.domain}"; }) entries)
  );

  cnameLines = lib.mapAttrsToList
    (name: target: "${name} 300 IN CNAME ${target}") dns.cnames;

  zoneText = lib.concatStringsSep "\n"
    ([ "$ORIGIN ${cfg.domain}." ] ++ cnameLines);
in
{
  config = {
    users.groups.blocky-secrets = { };
    sops.secrets.domains = {
      sopsFile = ../../secrets/dragonsreach.yaml;
      group = "blocky-secrets";
      mode = "0440";
    };

    # services.blocky runs under DynamicUser, so the only way to reach the
    # secret is a supplementary group.
    systemd.services.blocky.serviceConfig.SupplementaryGroups = [ "blocky-secrets" ];

    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = 53;
          http = 4000;
        };

        # Local knot-resolver (modules/router/knot-resolver.nix), which recurses
        # from the root instead of forwarding to a public DoH provider. Blocky
        # is a forwarder and can't chase CNAMEs from an upstream; kresd can, so
        # resolution lives there and blocky stays a policy layer.
        #
        # Same host as blocky, so this adds no new failure domain. No
        # bootstrapDns needed: the upstream is a literal address, not a name.
        upstreams.groups.default = [ "tcp+udp:127.0.0.1:5353" ];

        blocking = {
          denylists = {
            ads = [
              "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
            ];
            local = [ config.sops.secrets.domains.path ];
          };
          clientGroupsBlock = {
            default = [ "ads" "local" ];
          };
        };

        conditional = {
          # The *.garvey.sh zones are deliberately NOT here -- they are kresd
          # forward stubs (modules/router/knot-resolver.nix). A mapping here
          # would short-circuit straight to the authoritative server, and blocky
          # would hand back Knot's CNAME-plus-referral without chasing it,
          # breaking clients that don't re-query (musl/Alpine).
          #
          # home.arpa stays: k8s_gateway emits only A/AAAA and never a CNAME, so
          # it can't produce a partial answer, and home.arpa is an RFC 8375
          # special-use name a recursive resolver may decline to handle. Retired
          # at the cutover.
          mapping = {
            "k8s.home.arpa" = "[2001:470:482f:2::53]";
          };
        };

        customDNS = {
          # garveyShOverrides keys are already fully-qualified (oci.garvey.sh),
          # so merge them in directly without the home.arpa FQDN suffix.
          mapping = dnsMapping // dns.garveyShOverrides;
          zone = zoneText;
        };

        dns64 = {
          enable = true;
          prefixes = [ "64:ff9b::/96" ];
        };

        queryLog = {
          type = "none";
        };
      };
    };

    # Ensure the router itself uses blocky for DNS
    networking.nameservers = [ "127.0.0.1" ];

    # Disable systemd-resolved since blocky handles DNS
    services.resolved.enable = false;
  };
}
