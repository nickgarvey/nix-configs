{ config, lib, pkgs, ... }:

# Palworld dedicated server, run from the official
# `thijsvanloef/palworld-server-docker` OCI image. AUTO_PAUSE_ENABLED makes the
# image save the world and SIGSTOP the server after AUTO_PAUSE_TIMEOUT_EST
# seconds with zero players, then wake automatically on a connection knock —
# so there's no separate start/stop control surface, just leave it running.
#
# The container runs in its own network namespace with a real, directly
# routable IPv6 address in talos's delegated /64 (2001:470:482f:201::/64,
# shared with garage and vLLM) — a veth pair into vmbr0, the same mechanism
# modules/llms/vllm.nix uses. No NAT, no host port publish: the container is
# reachable directly at its own address.

let
  cfg = config.homelab.palworld;

  palworldUnit = "${config.virtualisation.oci-containers.containers.palworld.serviceName}.service";

  # talos's delegated /64 (see hosts/talos/configuration.nix's
  # homelab.network.bridge.ipv6.extraAddresses and
  # modules/router/lan-ipv6.nix). Shared with garage (::2) and vLLM (::3);
  # Palworld takes ::4.
  netnsName = "palworld";
  vethHost = "veth-palworld-h";
  vethCtr = "veth-palworld-c";
  containerAddress = "2001:470:482f:201::4";
  # The router deliberately never advertises a default IPv6 route to LAN
  # clients (modules/router/lan-ipv6.nix: RouterLifetimeSec = 0 — HE tunnel
  # prefixes are frequently flagged by major providers), so real internet
  # egress on this network happens over IPv4 for every physical host.
  #
  # SteamCMD (which the image shells out to, on every container start when
  # UPDATE_ON_BOOT=true — not just first install, per
  # /home/steam/server/start.sh in the image) needs outbound internet to log
  # in and fetch/update the dedicated-server binaries, which this image
  # doesn't bundle. The repo's usual answer for a v6-only netns needing
  # outbound access is a NAT64 route (modules/containers/storj-gateway.nix's
  # nspawn-nat64-route6, via the router's Jool gateway,
  # modules/router/nat64.nix) rather than a real v4 address — tried first
  # here for the same reason. It partially works: HTTP/CDN fetches through
  # it succeed (verified: `curl` to steamcdn-a.akamaihd.net via the
  # synthesized 64:ff9b::/96 address returns 200). But SteamCMD's own
  # anonymous-login handshake (the Steam3 CM protocol, needed before any
  # download starts) does not complete through the NAT64 path — verified
  # empirically twice, each left retrying for 4+ minutes with zero success,
  # versus ~4 seconds to connect over native IPv4. Since that login step
  # runs on every restart, not just once, an unreliable path there is a
  # real operational risk, not just a slow first boot. Real IPv4 it is.
  # 10.28.8.81 is free and outside kea's dynamic pool
  # (modules/router/kea-dhcp.nix, 10.28.100.1-254).
  containerAddressV4 = "10.28.8.81";
in
{
  options.homelab.palworld = {
    enable = lib.mkEnableOption "Palworld dedicated server (official OCI image, run via podman)";

    image = lib.mkOption {
      type = lib.types.str;
      # thijsvanloef/palworld-server-docker:v2.7.1 pinned by the tag's OCI
      # image index digest (multi-arch; podman resolves the right platform
      # manifest from it the same way a tag pull would, just reproducibly).
      default = "ghcr.io/thijsvanloef/palworld-server-docker@sha256:401d3eb5c053bcd72949e1ede8c4e38be5e5ad66be7272ac37940706df0aeb2f";
      description = "Container image (pinned by digest) to run.";
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      default = "Palworld";
      description = "Server name shown in the server browser / connect UI.";
    };

    players = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = "Maximum concurrent players.";
    };

    autoPauseTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Seconds with zero players before the image saves the world and
        SIGSTOPs the server (AUTO_PAUSE_TIMEOUT_EST). It wakes automatically
        on the next connection attempt.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.virtualisation.podman.enable;
      message = "homelab.palworld requires virtualisation.podman.enable = true.";
    }];

    # No networking.firewall rule needed: vmbr0 is a trusted interface
    # (modules/networking/networkd.nix) and Palworld's netns is reached
    # directly at its own address, not via a port published on talos's own
    # addresses.

    sops.secrets.palworld-admin-password = {
      sopsFile = ../../secrets/palworld.yaml;
      key = "admin_password";
    };
    sops.secrets.palworld-server-password = {
      sopsFile = ../../secrets/palworld.yaml;
      key = "server_password";
    };
    sops.templates."palworld.env" = {
      content = ''
        ADMIN_PASSWORD=${config.sops.placeholder.palworld-admin-password}
        SERVER_PASSWORD=${config.sops.placeholder.palworld-server-password}
      '';
      # Without this, rotating either password silently doesn't take effect
      # until something else restarts the unit — sops-nix doesn't restart
      # units on template content changes unless told to.
      restartUnits = [ palworldUnit ];
    };

    # uid/gid 1000 to match PUID/PGID below, so the world files the container
    # writes are owned by a real user rather than root.
    systemd.tmpfiles.rules = [
      "d /var/lib/palworld 0750 1000 1000 - -"
    ];

    # nixpkgs has no declarative option for podman networks, so build a
    # netns + veth pair into vmbr0 by hand, ahead of the container — same
    # mechanism and same hard-won details as modules/llms/vllm.nix's
    # vllm-netns.service. Every step tolerates re-running (idempotent across
    # rebuilds/restarts).
    systemd.services.palworld-netns = {
      description = "Create the netns/veth network for Palworld (bridged onto vmbr0)";
      wantedBy = [ "multi-user.target" ];
      before = [ palworldUnit ];
      after = [ "sys-subsystem-net-devices-vmbr0.device" ];
      wants = [ "sys-subsystem-net-devices-vmbr0.device" ];
      path = [ pkgs.iproute2 pkgs.procps ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "palworld-netns-start" ''
          set -euo pipefail
          ip netns list | cut -d' ' -f1 | grep -qx ${netnsName} || ip netns add ${netnsName}
          ip link show ${vethHost} &>/dev/null || {
            ip link add ${vethHost} type veth peer name ${vethCtr}
            ip link set ${vethCtr} netns ${netnsName}
          }
          ip link set ${vethHost} master vmbr0
          ip link set ${vethHost} up
          if ip netns exec ${netnsName} ip link show ${vethCtr} &>/dev/null; then
            ip netns exec ${netnsName} ip link set ${vethCtr} name eth0
          fi
          # autoconf=0: keep only our static address, no second SLAAC'd one.
          # accept_ra stays on (kernel default; set explicitly for clarity)
          # so eth0 learns on-link prefixes and RA-advertised routes exactly
          # like any other host on vmbr0 (including the site /48 route from
          # modules/router/lan-ipv6.nix) — a hand-rolled static route via
          # talos's own vmbr0 address looks equivalent but is NOT: talos
          # treats the whole main-LAN /64 as on-link and answers NDP for it
          # directly rather than forwarding, which silently breaks delivery
          # to LAN hosts actually reached via the router. accept_ra_rt_info_max_plen
          # must be raised too — it's snapshotted from `default` (0) at
          # interface-creation time, same gotcha modules/containers/common.nix
          # documents for nspawn, so without it the /48 Route Information
          # Option is silently discarded as too specific.
          ip netns exec ${netnsName} sysctl -qw net.ipv6.conf.eth0.autoconf=0
          ip netns exec ${netnsName} sysctl -qw net.ipv6.conf.eth0.accept_ra=1
          ip netns exec ${netnsName} sysctl -qw net.ipv6.conf.eth0.accept_ra_rt_info_max_plen=64
          ip netns exec ${netnsName} ip link set lo up
          ip netns exec ${netnsName} ip link set eth0 up
          ip netns exec ${netnsName} ip -6 addr replace ${containerAddress}/64 dev eth0
          # IPv4 for real internet egress (SteamCMD's login handshake — see
          # containerAddressV4 comment above for why NAT64 isn't used here).
          # /16 matches vmbr0's own LAN prefix so the kernel treats the whole
          # LAN as on-link, same as every physical host.
          ip netns exec ${netnsName} ip -4 addr replace ${containerAddressV4}/16 dev eth0
          ip netns exec ${netnsName} ip -4 route replace default via 10.28.0.1 dev eth0
        '';
      };
    };

    virtualisation.oci-containers = {
      backend = "podman";
      containers.palworld = {
        image = cfg.image;
        autoStart = true;
        # Join the netns built by palworld-netns.service above rather than a
        # podman-managed network — gives the container a real routable
        # address with no NAT/port-publish involved.
        networks = [ "ns:/var/run/netns/${netnsName}" ];
        # NET_RAW/NET_ADMIN: the image's documented requirement for
        # auto-pause's NFLOG/knockd connection detector. --dns: with
        # --network=ns:<path>, podman doesn't manage DNS, so the container
        # would otherwise inherit talos's own /etc/resolv.conf (Tailscale +
        # IPv4 LAN resolvers), unreachable from this IPv6-only netns.
        extraOptions = [
          "--cap-add=NET_RAW"
          "--cap-add=NET_ADMIN"
          "--dns=2001:470:482f::1"
        ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          PORT = "8211";
          QUERY_PORT = "27015";
          PLAYERS = toString cfg.players;
          SERVER_NAME = cfg.serverName;
          COMMUNITY = "false";
          RCON_ENABLED = "true";
          REST_API_ENABLED = "true";
          ENABLE_PLAYER_LOGGING = "true";
          # Both required for AUTO_PAUSE_ENABLED (see module doc comment).
          AUTO_PAUSE_ENABLED = "true";
          AUTO_PAUSE_TIMEOUT_EST = toString cfg.autoPauseTimeoutSec;
          ENABLE_PERF_THREADING_ARGS = "true";
        };
        environmentFiles = [ config.sops.templates."palworld.env".path ];
        volumes = [ "/var/lib/palworld:/palworld" ];
      };
    };

    # First start pulls the multi-GB image; give it room. Generous stop
    # timeout too, so the image's shutdown hook (autopause stop -> RCON save
    # -> clean exit) isn't SIGKILLed mid-save.
    systemd.services."${config.virtualisation.oci-containers.containers.palworld.serviceName}" = {
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "600";
        TimeoutStopSec = lib.mkForce "120";
      };
      after = [ "palworld-netns.service" ];
      requires = [ "palworld-netns.service" ];
    };
  };
}
