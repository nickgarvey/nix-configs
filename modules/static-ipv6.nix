{ config, lib, ... }:

let
  inherit (import ./router/lan-hosts.nix) lanHosts;
  hostname = config.networking.hostName;
  hostEntry = lib.findFirst (h: h.hostname == hostname) null lanHosts;
in
{
  config = lib.mkIf (hostEntry != null && hostEntry.ipv6 != null && hostEntry.mac != "") {
    systemd.network.networks."25-ipv6-static" = {
      matchConfig.MACAddress = hostEntry.mac;
      address = [ "${hostEntry.ipv6}/64" ];
    };
  };
}
