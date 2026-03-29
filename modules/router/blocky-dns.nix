{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ./lan-hosts.nix) lanHosts dnsAliases;

  allDnsEntries = lanHosts ++ dnsAliases;

  # Build customDNS mapping: both short names and FQDNs
  dnsMapping = builtins.listToAttrs (
    (map (h: { name = h.hostname;                    value = h.ipv4; }) allDnsEntries) ++
    (map (h: { name = "${h.hostname}.${cfg.domain}"; value = h.ipv4; }) allDnsEntries)
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

        customDNS = {
          mapping = dnsMapping;
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
