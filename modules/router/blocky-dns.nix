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

        upstreams.groups.default = [
          "https://dns.quad9.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
        ];

        bootstrapDns = [
          { upstream = "https://dns.quad9.net/dns-query"; ips = [ "9.9.9.9" "149.112.112.112" ]; }
          { upstream = "https://cloudflare-dns.com/dns-query"; ips = [ "1.1.1.1" "1.0.0.1" ]; }
        ];

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
          mapping = {
            "k8s.home.arpa" = "[2001:470:482f:2::53]";
            # Same k8s_gateway backend, which now serves both zones. First step
            # toward moving off home.arpa; k8s.home.arpa stays until cutover.
            "k8s.home.garvey.sh" = "[2001:470:482f:2::53]";
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
