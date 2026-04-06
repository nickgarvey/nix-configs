{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ../lan-hosts.nix) lanHosts;

  hostsWithMac = builtins.filter (h: h.mac != "") lanHosts;
in
{
  config = {
    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = [ cfg.lanInterface ];
        };

        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp4.leases";
        };

        valid-lifetime = 86400;
        renew-timer = 43200;
        rebind-timer = 64800;

        subnet4 = [
          {
            id = 1;
            subnet = cfg.lanSubnet;
            pools = [
              { pool = "10.28.100.1 - 10.28.100.254"; }
            ];
            option-data = [
              { name = "routers";            data = cfg.lanAddress; }
              { name = "domain-name-servers"; data = cfg.lanAddress; }
              { name = "domain-name";         data = cfg.domain; }
              { name = "vendor-encapsulated-options"; data = "01:04:0a:1c:0f:cb"; csv-format = false; }
            ];
            reservations = map (host: {
              hw-address = host.mac;
              ip-address = host.ipv4;
              hostname = host.hostname;
            }) hostsWithMac;
          }
        ];
      };
    };

    # IPv6: Use Router Advertisements via systemd-networkd for SLAAC
    # The LAN network config is extended here with IPv6 RA settings.
    # The actual prefix is configured in he-tunnel.nix when the tunnel is enabled.
    systemd.network.networks."10-lan" = {
      networkConfig = {
        IPv6SendRA = lib.mkDefault false; # Enabled by he-tunnel.nix when tunnel is configured
      };
    };
  };
}
