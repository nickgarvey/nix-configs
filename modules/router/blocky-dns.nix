{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ../lan-hosts.nix) lanHosts dnsAliases;

  allDnsEntries = lanHosts ++ dnsAliases;

  # Build customDNS mapping: both short names and FQDNs
  # Blocky accepts comma-separated IPs for multiple records per hostname
  ipStr = h: if h.ipv6 != null then "${h.ipv4},${h.ipv6}" else h.ipv4;
  dnsMapping = builtins.listToAttrs (
    (map (h: { name = h.hostname;                    value = ipStr h; }) allDnsEntries) ++
    (map (h: { name = "${h.hostname}.${cfg.domain}"; value = ipStr h; }) allDnsEntries)
  );
in
{
  config = {
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
          };
          clientGroupsBlock = {
            default = [ "ads" ];
          };
        };

        conditional = {
          mapping = {
            "k8s.home.arpa" = "10.28.15.207";
          };
        };

        customDNS = {
          mapping = dnsMapping;
          # CNAMEs for k8s LoadBalancer services — resolved dynamically via k8s-gateway
          zone = ''
            $ORIGIN ${cfg.domain}.
            plex          300 IN CNAME plex.plex.k8s.${cfg.domain}.
            unifi         300 IN A    10.28.0.1
            trmnl-display 300 IN CNAME trmnl-display.trmnl-display.k8s.${cfg.domain}.
          '';
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
