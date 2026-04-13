{ config, lib, pkgs, ... }:

# NAT64 via Jool in a network namespace.
#
# Jool's netfilter mode bypasses remaining netfilter hooks in the same
# namespace, which breaks masquerade. Running Jool in its own namespace
# solves this: translated IPv4 packets exit via veth into the main
# namespace, where normal nftables FORWARD + masquerade apply.
#
# Topology:
#   main ns:  jool0 (10.99.0.1/30, fd99::1/126)  ←veth→  jool1 (10.99.0.2/30, fd99::2/126)  :nat64 ns
#
# Flow:
#   Pod → 64:ff9b::x.x.x.x → router routes via jool0 → jool1 in nat64 ns
#   → Jool translates to IPv4 (src=10.99.0.2) → default route via jool1
#   → exits to jool0 in main ns → routes to WAN → nftables masquerade
#   Response reverses the path.

let
  cfg = config.routerConfig;
  jool = config.boot.kernelPackages.jool;
  jool-cli = pkgs.jool-cli;

  joolConf = (pkgs.formats.json { }).generate "jool-nat64.conf" {
    instance = "default";
    framework = "netfilter";
    global.pool6 = "64:ff9b::/96";
    pool4 = [
      { protocol = "TCP";  prefix = "10.99.0.2/32"; "port range" = "1-65535"; }
      { protocol = "UDP";  prefix = "10.99.0.2/32"; "port range" = "1-65535"; }
      { protocol = "ICMP"; prefix = "10.99.0.2/32"; "port range" = "1-65535"; }
    ];
  };
in
{
  config = {
    # Jool kernel module (loaded globally, instances are per-namespace)
    boot.extraModulePackages = [ jool ];
    environment.systemPackages = [ jool-cli ];

    systemd.services.jool-nat64 = {
      description = "Jool NAT64 in network namespace";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 pkgs.procps jool-cli pkgs.kmod ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "jool-nat64-start" ''
          set -e

          # Create namespace and veth pair
          ip netns add nat64
          ip link add jool0 type veth peer name jool1
          ip link set jool1 netns nat64

          # Configure main-namespace side
          ip addr add 10.99.0.1/30 dev jool0
          ip addr add fd99::1/126 dev jool0
          ip link set jool0 up
          ip route add 64:ff9b::/96 via fd99::2 dev jool0

          # Configure namespace side
          ip netns exec nat64 ip link set lo up
          ip netns exec nat64 ip link set jool1 up
          ip netns exec nat64 ip addr add 10.99.0.2/30 dev jool1
          ip netns exec nat64 ip addr add fd99::2/126 dev jool1
          ip netns exec nat64 ip route add default via 10.99.0.1 dev jool1
          ip netns exec nat64 ip -6 route add default via fd99::1 dev jool1
          ip netns exec nat64 sysctl -w net.ipv6.conf.all.forwarding=1
          ip netns exec nat64 sysctl -w net.ipv4.ip_forward=1

          # Load Jool and create instance inside the namespace
          modprobe jool
          ip netns exec nat64 jool file handle ${joolConf}
        '';
        ExecStop = pkgs.writeShellScript "jool-nat64-stop" ''
          ip netns exec nat64 jool instance remove || true
          ip link del jool0 || true
          ip netns del nat64 || true
        '';
      };
    };
  };
}
