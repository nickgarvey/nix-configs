# Serves a web page listing every device on the LAN: the DHCP reservations
# generated from lan-hosts.nix, the active dynamic leases, and anything the
# router only knows from its ARP/NDP tables.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.routerConfig;
  lan-table = inputs.lan-table.packages.${pkgs.stdenv.hostPlatform.system}.default;
  port = 8080;

  # networkctl reports when a lease expires but not how long it was granted
  # for, so the page can only work out a lease's age if it is told the grant.
  # Read from the DHCP server's own config (modules/router/dhcp.nix) rather
  # than restated here, so the two cannot drift apart.
  leaseTimeSec = config.systemd.network.networks."10-lan".dhcpServerConfig.DefaultLeaseTimeSec;
in
{
  config = {
    systemd.services.lan-table = {
      description = "LAN inventory web page";
      wantedBy = [ "multi-user.target" ];
      # networkd owns both data sources: the DHCP server state comes over its
      # varlink socket, and the LAN bridge has to exist before the neighbour
      # table means anything.
      after = [ "systemd-networkd.service" ];
      wants = [ "systemd-networkd.service" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${lan-table}/bin/lan-table"
          "--listen :${toString port}"
          "--interface ${cfg.lanInterface}"
          "--lease-time ${toString leaseTimeSec}s"
        ];
        Restart = "on-failure";
        RestartSec = 5;

        # Nothing here is privileged: /run/systemd/netif/io.systemd.Network is
        # world-connectable and the neighbour tables are readable by anyone,
        # so the service needs no identity of its own and writes nothing.
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        # AF_NETLINK is load-bearing — `ip neigh` reads the neighbour table
        # over rtnetlink, and without it every IPv6 column would be empty.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
      };
    };
  };
}
