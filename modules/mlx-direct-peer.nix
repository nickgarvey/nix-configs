# Wires up the 25G ConnectX-4 direct link between aboleth and tarrasque:
# the fd28::/64 point-to-point address, a /64 route to the peer's delegated
# prefix (so all peer-bound IPv6 traffic — host + containers — rides the
# 25G), and mlx5 firmware-hang recovery. The pair table below is the single
# source of truth for the link.
{ config, lib, ... }:

let
  cfg = config.services.mlxDirectPeer;
  hostname = config.networking.hostName;

  pairs = {
    aboleth = {
      mac = "24:8a:07:3b:eb:fc";
      pciAddresses = [ "0000:02:00.0" "0000:02:00.1" ];
      fd28 = "fd28::2";
      peerPrefix = "2001:470:482f:201::/64";
      peerFd28 = "fd28::1";
    };
    tarrasque = {
      mac = "24:8a:07:3b:eb:ec";
      pciAddresses = [ "0000:11:00.0" "0000:11:00.1" ];
      fd28 = "fd28::1";
      peerPrefix = "2001:470:482f:200::/64";
      peerFd28 = "fd28::2";
    };
  };

  me = pairs.${hostname};
in
{
  imports = [ ./mlx-firmware-recovery.nix ];

  options.services.mlxDirectPeer.enable =
    lib.mkEnableOption "25G direct ConnectX-4 peer link";

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pairs ? ${hostname};
      message = "services.mlxDirectPeer: no pair entry for host '${hostname}'";
    }];

    services.mlxFirmwareRecovery = {
      enable = true;
      pciAddresses = me.pciAddresses;
    };

    systemd.network.networks."30-mlx-direct" = {
      matchConfig.MACAddress = me.mac;
      networkConfig.DHCP = "no";
      linkConfig.MTUBytes = "9000";
      address = [ "${me.fd28}/64" ];
      routes = [
        { Destination = me.peerPrefix; Gateway = me.peerFd28; }
      ];
    };
  };
}
