# Routed IPv6 mesh over direct Thunderbolt/USB4 cables between the storage nodes, using FRR OpenFabric.
#
# Each node has one /128 on a dummy interface, reachable from the other nodes
# whichever cable carries it: OpenFabric finds the neighbour on each
# Thunderbolt link and routes through the third node if a direct cable is
# down. Nothing here depends on which port a cable is plugged into.
{ config, lib, pkgs, ... }:

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

  inherit (import ./lan-hosts.nix) lanHosts;
  lanV6 = name: (lib.findFirst (h: h.hostname == name) null lanHosts).ipv6;
  peers = lib.filter (n: n != hostname) nodes;
  meshAddress = n: "${meshPrefix}${toString (lib.lists.findFirstIndex (x: x == n) null nodes + 1)}";
in
{
  # thunderbolt_net is loaded late, by thunderbolt-net-load below, not
  # autoloaded when a peer appears. The thunderbolt driver's control channel
  # can hand one config-write reply to another in-flight write to the same
  # router (tb_cfg_match only compares route, type, size and the retry
  # index), and XDomain lane bonding writes without tb->lock. At boot, one
  # link's DMA path setup (started by thunderbolt_net) then races the other
  # link's lane bonding, both writes fail, and one link comes up with no
  # data path while the other stays single-lane. Loading thunderbolt_net
  # only once both peers are enumerated (i.e. done bonding) avoids that.
  boot.blacklistedKernelModules = [ "thunderbolt_net" ];

  systemd.services.thunderbolt-net-load = {
    description = "Load thunderbolt_net once all mesh peers are enumerated";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.kmod ];
    script = ''
      # A peer shows up as 0-N (N > 0) only after its lane bonding and
      # property exchange finish. Give up waiting after 30s so a node with a
      # cable out still loads the module.
      for _ in $(seq 60); do
        peers=$(ls -d /sys/bus/thunderbolt/devices/0-[1-9] 2>/dev/null | wc -l)
        [ "$peers" -ge ${toString (builtins.length nodes - 1)} ] && break
        sleep 0.5
      done
      echo "loading thunderbolt_net with $peers peer(s) enumerated"
      modprobe thunderbolt_net
    '';
  };

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
    # Last-resort path to each peer's mesh address over the LAN, for when a
    # node has no Thunderbolt path to it at all (cables out, or a link up but
    # dead). These are floating static routes: distance 250 loses to
    # OpenFabric's 115, so they are only installed once fabricd has withdrawn
    # every mesh route to that peer, including the two-hop one through the
    # third node. Ceph's cluster network then runs over the LAN instead of the
    # OSD being marked down. They live in FRR rather than networkd because
    # zebra would treat a kernel route as distance 0 and never install the
    # mesh route. (staticd always runs; it needs no enable.)
    config = lib.concatMapStrings (peer: ''
      ipv6 route ${meshAddress peer}/128 ${lanV6 peer} 250
    '') peers + ''
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

  # Mesh health, pushed every 60s and alerted on in k8s-gitops
  # manifests/prometheus/rules/mesh.yaml. One "kind label value" line each:
  #   links_up - N       Thunderbolt links with carrier (2 when both cables are
  #                      in); a pulled cable removes its interface instead of
  #                      taking it down, so this counts carriers.
  #   rx IFACE N         received packets on a link with carrier. OpenFabric
  #                      hellos arrive every second, so a count that stops
  #                      rising means the link is up but dead.
  #   lanes PEER N       lanes of the XDomain link to PEER (2 when bonded).
  #   via_tb PEER 0|1    whether traffic to PEER's mesh address goes over
  #                      Thunderbolt (0: the LAN fallback route, or none).
  homelab.metrics.sources.mesh_links = {
    type = "exec";
    mode = "scheduled";
    scheduled.exec_interval_secs = 60;
    command = [
      (pkgs.writeShellScript "mesh-health" ''
        up=0
        for i in /sys/class/net/thunderbolt*; do
          [ -e "$i" ] || continue
          [ "$(cat "$i/carrier" 2>/dev/null)" = 1 ] || continue
          up=$((up + 1))
          echo "rx $(basename "$i") $(cat "$i/statistics/rx_packets")"
        done
        echo "links_up - $up"
        for d in /sys/bus/thunderbolt/devices/0-[1-9]; do
          [ -e "$d/device_name" ] || continue
          echo "lanes $(cat "$d/device_name") $(cat "$d/rx_lanes")"
        done
        ${lib.concatMapStrings (peer: ''
          dev=$(${pkgs.iproute2}/bin/ip -6 route get ${meshAddress peer} 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2)
          case "$dev" in thunderbolt*) echo "via_tb ${peer} 1" ;; *) echo "via_tb ${peer} 0" ;; esac
        '') peers}
      '')
    ];
  };
  homelab.metrics.transforms = let
    # kind -> metric name and the tag the line's label becomes (null: none).
    meshMetrics = {
      links_up = { name = "homelab_mesh_links_up"; label = null; };
      rx = { name = "homelab_mesh_link_rx_packets"; label = "interface"; };
      lanes = { name = "homelab_mesh_link_lanes"; label = "peer"; };
      via_tb = { name = "homelab_mesh_peer_via_thunderbolt"; label = "peer"; };
    };
  in {
    mesh_links_fields = {
      type = "remap";
      inputs = [ "mesh_links" ];
      source = ''
        parts = split(strip_whitespace!(to_string!(.message)), " ")
        .kind = parts[0]
        .label = parts[1]
        .value = to_int!(parts[2])
      '';
    };
    # log_to_metric drops an event if any of its metrics' fields is missing,
    # so each kind of line gets its own transform.
    mesh_links_route = {
      type = "route";
      inputs = [ "mesh_links_fields" ];
      route = lib.mapAttrs (kind: _: ''.kind == "${kind}"'') meshMetrics;
    };
  } // lib.mapAttrs' (kind: m: lib.nameValuePair "mesh_${kind}_metric" {
    type = "log_to_metric";
    inputs = [ "mesh_links_route.${kind}" ];
    metrics = [{
      type = "gauge";
      field = "value";
      inherit (m) name;
      tags = { inherit hostname; } // lib.optionalAttrs (m.label != null) { ${m.label} = "{{ label }}"; };
    }];
  }) meshMetrics;
}
