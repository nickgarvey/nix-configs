# Routed IPv6 mesh over direct Thunderbolt/USB4 cables between the storage nodes, using FRR OpenFabric.
#
# Each node has one /128 on a dummy interface, reachable from the other nodes
# whichever cable carries it: OpenFabric finds the neighbour on each
# Thunderbolt link and routes through the third node if a direct cable is
# down. Nothing here depends on which port a cable is plugged into.
{ config, lib, ... }:

let
  # Position in this list gives the node's mesh address and OpenFabric ID.
  nodes = [ "joor" "zah" "frul" ];
  meshPrefix = "fd2f:b7dd:75bc::";

  hostname = config.networking.hostName;
  index = lib.lists.findFirstIndex (n: n == hostname) null nodes;
  num =
    if index == null
    then throw "thunderbolt-mesh.nix: ${hostname} is not in the mesh node list"
    else index + 1;

  # thunderbolt_net names its interfaces thunderbolt0, thunderbolt1, ... in
  # the order links come up; with two USB4 ports there are at most two.
  tbInterfaces = [ "thunderbolt0" "thunderbolt1" ];
in
{
  boot.kernelModules = [ "thunderbolt_net" ];

  # Carries traffic between the other two nodes when their direct cable is down.
  homelab.network.ipv6Forward = true;

  systemd.network.netdevs."20-mesh0".netdevConfig = {
    Name = "mesh0";
    Kind = "dummy";
  };
  systemd.network.networks."20-mesh0" = {
    matchConfig.Name = "mesh0";
    address = [ "${meshPrefix}${toString num}/128" ];
    linkConfig.RequiredForOnline = "no";
  };

  systemd.network.networks."30-thunderbolt" = {
    matchConfig.Driver = "thunderbolt-net";
    networkConfig = {
      # Link-local only: OpenFabric uses it for neighbours and next hops.
      LinkLocalAddressing = "ipv6";
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    linkConfig = {
      MTUBytes = "65520";
      # A missing cable must not hold up boot.
      RequiredForOnline = "no";
    };
  };

  # networkd would otherwise delete the routes and nexthops FRR installs
  # whenever it reconfigures a link.
  systemd.network.config.networkConfig = {
    ManageForeignRoutes = false;
    ManageForeignNextHops = false;
  };

  networking.firewall.trustedInterfaces = tbInterfaces;

  services.frr = {
    fabricd.enable = true;
    config = ''
      interface mesh0
       ipv6 router openfabric 1
       openfabric passive
      exit
    '' + lib.concatMapStrings (i: ''
      interface ${i}
       ipv6 router openfabric 1
       openfabric hello-interval 1
       openfabric hello-multiplier 3
      exit
    '') tbInterfaces + ''
      router openfabric 1
       net 49.0000.0000.000${toString num}.00
       lsp-gen-interval 1
      exit
    '';
  };
}
