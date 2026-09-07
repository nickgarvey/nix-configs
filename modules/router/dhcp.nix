{ config, lib, pkgs, ... }:

let
  cfg = config.routerConfig;
  inherit (import ../networking/lan-hosts.nix) lanHosts;

  hostsWithMac = builtins.filter (h: h.mac != "") lanHosts;
in
{
  config = {
    # DHCPv4 for the LAN bridge, served by systemd-networkd itself. The static
    # leases are the same lan-hosts.nix table blocky and the knot zone read, so
    # a host's address and its DNS name come from one place.
    #
    # IPv6 is RA/SLAAC only -- see lan-ipv6.nix. The RA default is seeded here
    # and flipped by he-tunnel.nix once the tunnel supplies a prefix.
    systemd.network.networks."10-lan" = {
      networkConfig = {
        DHCPServer = true;
        IPv6SendRA = lib.mkDefault false;
      };

      dhcpServerConfig = {
        # Dynamic pool 10.28.100.1-254, expressed as an offset from the
        # 10.28.0.0 subnet address: 100 * 256 + 1.
        PoolOffset = 25601;
        PoolSize = 254;

        # MaxLeaseTimeSec defaults to 12h and would cap a client that asks for
        # longer, so it is set alongside the default rather than left alone.
        DefaultLeaseTimeSec = 86400;
        MaxLeaseTimeSec = 86400;

        EmitRouter = true;
        EmitDNS = true;
        DNS = [ cfg.lanAddress ];
        EmitDomain = true;
        Domain = cfg.domain;
      };

      # Reservation addresses live outside the pool but inside the /16, which
      # networkd allows: it only rejects a null address or a null/multicast MAC.
      dhcpServerStaticLeases = map (host: {
        dhcpServerStaticLeaseConfig = {
          MACAddress = host.mac;
          Address = host.ipv4;
          Hostname = host.hostname;
        };
      }) hostsWithMac;
    };
  };
}
