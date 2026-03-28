{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ./lan-hosts.nix) lanHosts;

  # Only include hosts with real MAC addresses whose IPs are within the LAN subnet.
  # During migration, hosts still on the old subnet (10.28.x.x) are excluded.
  hostsWithMac = builtins.filter (h:
    h.mac != "XX:XX:XX:XX:XX:XX" &&
    lib.hasPrefix (lib.removeSuffix ".0/16" cfg.lanSubnet) h.ipv4
  ) lanHosts;
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
              { pool = "10.29.100.1 - 10.29.100.254"; }
            ];
            option-data = [
              { name = "routers";            data = cfg.lanAddress; }
              { name = "domain-name-servers"; data = cfg.lanAddress; }
              { name = "domain-name";         data = cfg.domain; }
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
