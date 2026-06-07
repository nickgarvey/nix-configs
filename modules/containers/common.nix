{ config, lib, ... }:

# Shared nspawn container networking. Each container picks an attachment
# (how its NIC connects to the LAN) and an independent set of addresses.
# This module wires firewall/DNS/stateVersion defaults inside the
# container plus the right gateway/route configuration for the chosen
# combination, so per-service modules only own service config.
#
# Private bridge-attached containers deliberately get NO IPv6 default
# route — the 2001:470:482f::/48 prefix is HE-tunnel-routed and broker
# prefixes are reputation-flagged by major services. See
# modules/router/lan-ipv6.nix. Instead they get a static /48 route via
# hostBridgeAddress for intra-site reachability (router, k3s nodes,
# garage peers). Macvlan containers attach directly to the LAN and pick
# up the same /48 route via RA (the router advertises it as a non-default
# routed prefix).

let
  cfg = config.nspawn.network;

  networkOpts = { name, ... }: {
    options = {
      attachment = lib.mkOption {
        type = lib.types.enum [ "bridge" "macvlan" "host" ];
        description = ''
          How the container's NIC reaches the LAN.
            bridge:  veth pair into a Linux bridge on the host. Needs
                     hostBridge. Addresses are static — set localAddress
                     and/or localAddress6.
            macvlan: macvlan child on a host LAN interface. Needs
                     macvlanInterface. Default addressing is DHCP (v4) +
                     SLAAC (v6).
            host:    no isolation; shares the host's network namespace.
        '';
      };

      hostBridge = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host bridge to veth into. Required when attachment = \"bridge\".";
      };

      macvlanInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host LAN interface to attach a macvlan to. Required when
          attachment = "macvlan". The container will see this interface
          as `mv-<name>`. Must NOT be a Linux bridge — macvlan children
          can't communicate with bridge slave ports.
        '';
      };

      localAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Container IPv4 address with prefix length.
            bridge:  static address (requires ipv4Gateway).
            macvlan: usually null (DHCP); set for static.
            host:    not applicable.
        '';
      };

      localAddress6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Container IPv6 address with prefix length.
            bridge:  static address in a host-delegated /64 (requires
                     hostBridgeAddress for the /48 intra-site route).
            macvlan: usually null (SLAAC); set for static.
            host:    not applicable.
        '';
      };

      hostBridgeAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IPv6 address of the host bridge in the same /64 as
          localAddress6. Used as the next-hop for the /48 intra-site
          route installed inside the container. Required when localAddress6
          is set in bridge attachment.
        '';
      };

      ipv4Gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IPv4 default gateway. Required when localAddress is set in
          bridge attachment. Note: this populates
          `networking.defaultGateway` inside the container, but NixOS's
          scripted-networking machinery does not run when nspawn assigns
          the address itself, so the route isn't actually installed.
          Set ipv4DefaultRoute = true to install it explicitly.
        '';
      };

      ipv4DefaultRoute = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Install an IPv4 default route via ipv4Gateway inside the
          container. Needed for containers that initiate outbound IPv4
          traffic to the internet (e.g. Unifi reaching sso.ui.com).
          Bridge-attached only — macvlan picks up a default route from
          DHCP, and host attachment uses the host's routes.
        '';
      };

      ipv4Nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };

      ipv6Nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "2001:470:482f::1" ];
      };

      sitePrefix6 = lib.mkOption {
        type = lib.types.str;
        default = "2001:470:482f::/48";
        description = ''
          Intra-site IPv6 prefix routed via hostBridgeAddress for
          bridge-attached containers with an IPv6 address. NOT a default
          route — HE tunnel prefixes are reputation-flagged; see
          modules/router/lan-ipv6.nix.
        '';
      };
    };
  };

  mkContainer = name: net:
    let
      isBridge = net.attachment == "bridge";
      isMacvlan = net.attachment == "macvlan";
      isPrivate = isBridge || isMacvlan;
      hasV4 = net.localAddress != null;
      hasV6 = net.localAddress6 != null;
      # Install the /48 intra-site route when a bridge-attached
      # container has any IPv6 address (the static address sits in the
      # host's delegated /64; without the /48 route the container can
      # only talk within its own /64).
      addsIntraSiteRoute = isBridge && hasV6 && net.hostBridgeAddress != null;
      macvlanIface = "mv-${name}";
    in {
      autoStart = lib.mkDefault true;
      privateNetwork = isPrivate;
    } // lib.optionalAttrs (isBridge && net.hostBridge != null) {
      hostBridge = net.hostBridge;
    } // lib.optionalAttrs (isMacvlan && net.macvlanInterface != null) {
      macvlans = [ net.macvlanInterface ];
    } // lib.optionalAttrs (isBridge && hasV4) {
      localAddress = net.localAddress;
    } // lib.optionalAttrs (isBridge && hasV6) {
      localAddress6 = net.localAddress6;
    } // {
      config = { lib, pkgs, ... }: {
        imports = [ ../networking/ipv6-accept-ra-routes.nix ];

        # systemd-nspawn creates the container's veth (renamed to eth0
        # inside the netns) BEFORE the container's userspace systemd-sysctl
        # runs. The per-interface accept_ra_rt_info_max_plen is snapshotted
        # from `default` at iface creation, so eth0 keeps the boot-time
        # value of 0 even after the shared module raises `default` to 64.
        # Set the per-interface value explicitly so it applies after the
        # interface exists.
        boot.kernel.sysctl."net.ipv6.conf.eth0.accept_ra_rt_info_max_plen" = 64;

        networking = lib.mkMerge [
          {
            firewall.enable = lib.mkDefault false;
            useHostResolvConf = false;
          }
          (lib.mkIf (isBridge && hasV4) {
            defaultGateway = net.ipv4Gateway;
            nameservers = net.ipv4Nameservers;
          })
          (lib.mkIf (isBridge && hasV6 && !hasV4) {
            # Use IPv6 nameservers only when there's no IPv4 stack to
            # provide them. Dual-stack containers default to the IPv4
            # nameservers above.
            nameservers = net.ipv6Nameservers;
          })
          (lib.mkIf isMacvlan {
            # Macvlan container is on the LAN directly. Use DHCP on the
            # macvlan iface for v4; SLAAC + RA-learned routes handle v6.
            # RA on the LAN advertises the /48 routed prefix but
            # RouterLifetimeSec=0 — no default route is installed.
            useDHCP = false;
            interfaces.${macvlanIface}.useDHCP = true;
          })
        ];

        # Install the intra-site /48 route after the container's scripted
        # networking has assigned eth0's address. No IPv6 default route —
        # HE prefix reputation; see modules/router/lan-ipv6.nix.
        systemd.services."nspawn-intrasite-route6" = lib.mkIf addsIntraSiteRoute {
          description = "Add intra-site IPv6 route via host bridge";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-addresses-eth0.service" ];
          wants = [ "network-addresses-eth0.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.iproute2}/bin/ip -6 route replace ${net.sitePrefix6} via ${net.hostBridgeAddress} dev eth0
          '';
        };

        # Install the IPv4 default route via ipv4Gateway. NixOS's
        # `networking.defaultGateway` would normally do this, but the
        # scripted-networking unit that installs it doesn't run when
        # nspawn assigns eth0's address itself.
        systemd.services."nspawn-default-route4" = lib.mkIf (isBridge && net.ipv4DefaultRoute) {
          description = "Add IPv4 default route via host bridge";
          wantedBy = [ "multi-user.target" ];
          before = [ "network-online.target" ];
          after = [ "sys-subsystem-net-devices-eth0.device" ];
          wants = [ "sys-subsystem-net-devices-eth0.device" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.iproute2}/bin/ip -4 route replace default via ${net.ipv4Gateway} dev eth0
          '';
        };

        system.stateVersion = lib.mkDefault "25.05";
      };
    };
in
{
  options.nspawn.network = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule networkOpts);
    default = { };
    description = "Per-container networking configuration. See common.nix.";
  };

  config = let
    hostBridge = config.homelab.network.bridge or null;
    # ipv6Forward is satisfied by either the homelab abstraction or a
    # direct sysctl (routers set forwarding via their own module rather
    # than homelab.network). The sysctl module normalizes int/str/bool,
    # so accept any truthy value.
    sysctlForward = config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" or false;
    hostHasIpv6Forward = (config.homelab.network.ipv6Forward or false)
      || sysctlForward == true
      || sysctlForward == 1
      || sysctlForward == "1";
    hostBridgeName = if hostBridge != null then hostBridge.name else null;
    networkdBridgeNames = lib.mapAttrsToList
      (_: nd: nd.netdevConfig.Name or null)
      (lib.filterAttrs
        (_: nd: (nd.netdevConfig.Kind or null) == "bridge")
        (config.systemd.network.netdevs or { }));
    allBridgeNames = lib.filter (n: n != null)
      ([ hostBridgeName ] ++ networkdBridgeNames);
    bridgeIsDeclared = bname: lib.elem bname allBridgeNames;
  in {
    assertions = lib.flatten (lib.mapAttrsToList (name: net:
      let
        isBridge = net.attachment == "bridge";
        isMacvlan = net.attachment == "macvlan";
        hasV4 = net.localAddress != null;
        hasV6 = net.localAddress6 != null;
      in [
        # Shape assertions: required fields per attachment + address.
        {
          assertion = isBridge -> net.hostBridge != null;
          message = "nspawn.network.${name}: attachment = \"bridge\" requires hostBridge.";
        }
        {
          assertion = isBridge -> (hasV4 || hasV6);
          message = "nspawn.network.${name}: bridge attachment requires at least one of localAddress / localAddress6.";
        }
        {
          assertion = (isBridge && hasV4) -> net.ipv4Gateway != null;
          message = "nspawn.network.${name}: bridge attachment with localAddress requires ipv4Gateway.";
        }
        {
          assertion = (isBridge && hasV6) -> net.hostBridgeAddress != null;
          message = "nspawn.network.${name}: bridge attachment with localAddress6 requires hostBridgeAddress (for the /48 intra-site route).";
        }
        {
          assertion = isMacvlan -> net.macvlanInterface != null;
          message = "nspawn.network.${name}: attachment = \"macvlan\" requires macvlanInterface.";
        }
        # ipv4DefaultRoute is bridge-only: macvlan picks up a default
        # route from DHCP, and host attachment uses the host's routes.
        {
          assertion = net.ipv4DefaultRoute -> isBridge;
          message = "nspawn.network.${name}: ipv4DefaultRoute = true is only valid for attachment = \"bridge\" (macvlan gets a default route via DHCP; host shares the host's routes).";
        }
        {
          assertion = net.ipv4DefaultRoute -> net.ipv4Gateway != null;
          message = "nspawn.network.${name}: ipv4DefaultRoute = true requires ipv4Gateway.";
        }
        {
          assertion = net.ipv4DefaultRoute -> hasV4;
          message = "nspawn.network.${name}: ipv4DefaultRoute = true requires localAddress (no IPv4 address means no IPv4 stack to route on).";
        }
        # CIDR sanity: addresses must carry a prefix length. Without
        # the `/N` suffix nspawn silently treats it as /32 / /128 and
        # the connected-route prefix doesn't match the LAN, breaking
        # reachability in confusing ways.
        {
          assertion = net.localAddress == null
            || lib.hasInfix "/" net.localAddress;
          message = "nspawn.network.${name}: localAddress = \"${toString net.localAddress}\" is missing a prefix length (e.g. \"10.28.0.4/16\").";
        }
        {
          assertion = net.localAddress6 == null
            || lib.hasInfix "/" net.localAddress6;
          message = "nspawn.network.${name}: localAddress6 = \"${toString net.localAddress6}\" is missing a prefix length (e.g. \"2001:470:482f:200::2/64\").";
        }
        # Wrong-attachment-for-option footguns. Each of these knobs is
        # only applied for one attachment; setting it elsewhere looks
        # like config but is silently dropped.
        {
          assertion = (net.attachment == "host") -> (
            net.hostBridge == null
            && net.macvlanInterface == null
            && net.localAddress == null
            && net.localAddress6 == null
            && net.hostBridgeAddress == null
            && net.ipv4Gateway == null
            && !net.ipv4DefaultRoute
          );
          message = "nspawn.network.${name}: attachment = \"host\" ignores all networking options (the container shares the host's netns). Remove hostBridge/macvlanInterface/localAddress*/ipv4*/hostBridgeAddress.";
        }
        {
          assertion = isBridge -> net.macvlanInterface == null;
          message = "nspawn.network.${name}: attachment = \"bridge\" doesn't use macvlanInterface — remove it.";
        }
        {
          assertion = isMacvlan -> net.hostBridge == null;
          message = "nspawn.network.${name}: attachment = \"macvlan\" doesn't use hostBridge — remove it (use macvlanInterface).";
        }
        # macvlan currently wires `useDHCP = true` and never applies a
        # static address. The localAddress docstring mentions "set for
        # static" but the code path isn't there; flag rather than fail
        # silently.
        {
          assertion = isMacvlan -> net.localAddress == null;
          message = "nspawn.network.${name}: attachment = \"macvlan\" with localAddress is not implemented (the module only wires DHCP). Either drop localAddress or extend common.nix to apply the static address.";
        }
        {
          assertion = isMacvlan -> net.localAddress6 == null;
          message = "nspawn.network.${name}: attachment = \"macvlan\" with localAddress6 is not implemented (the module only wires SLAAC via RA). Either drop localAddress6 or extend common.nix.";
        }
        {
          assertion = isMacvlan -> net.ipv4Gateway == null;
          message = "nspawn.network.${name}: attachment = \"macvlan\" doesn't use ipv4Gateway — macvlan picks up the default route from DHCP.";
        }
        {
          assertion = isMacvlan -> net.hostBridgeAddress == null;
          message = "nspawn.network.${name}: attachment = \"macvlan\" doesn't use hostBridgeAddress (no /48 intra-site route is installed; macvlan learns routes via RA).";
        }
        # hostBridgeAddress only matters when localAddress6 is set — it
        # defines the next-hop for the /48 route. Setting it without
        # localAddress6 is a silent no-op.
        {
          assertion = (net.hostBridgeAddress != null) -> hasV6;
          message = "nspawn.network.${name}: hostBridgeAddress is set but localAddress6 isn't — hostBridgeAddress is only used as the next-hop for the /48 intra-site route, which is only installed when localAddress6 is set.";
        }
        # Macvlan children don't communicate with a Linux bridge's slave
        # ports (kernel-level isolation). Catch the footgun at eval time.
        {
          assertion = isMacvlan -> !(bridgeIsDeclared net.macvlanInterface);
          message = "nspawn.network.${name}: macvlanInterface = \"${toString net.macvlanInterface}\" is a Linux bridge. Macvlan children can't talk to bridge slave ports — use attachment = \"bridge\" with hostBridge = \"${toString net.macvlanInterface}\" instead.";
        }

        # Host-level prerequisites.
        #
        # The host must declare the bridge via either homelab.network.bridge
        # or systemd.network.netdevs; without it, the container has nothing
        # to attach to.
        {
          assertion = isBridge -> bridgeIsDeclared net.hostBridge;
          message = "nspawn.network.${name}: bridge attachment needs the host to declare a bridge named \"${toString net.hostBridge}\" (via homelab.network.bridge or systemd.network.netdevs). Declared bridges: ${lib.concatStringsSep ", " allBridgeNames}.";
        }
        # IPv6 reachability across the /48 requires the host to forward.
        # The container's /48 route points at the host's bridge address;
        # the host then forwards to br-lan / he-ipv6 / other interfaces.
        # Without forwarding the frames are dropped silently.
        {
          assertion = (isBridge && hasV6) -> hostHasIpv6Forward;
          message = "nspawn.network.${name}: bridge attachment with localAddress6 requires the host to enable IPv6 forwarding (homelab.network.ipv6Forward = true, or boot.kernel.sysctl.\"net.ipv6.conf.all.forwarding\" = 1) so /48 traffic can leave the per-host /64.";
        }
        # Macvlan attaches to a real LAN interface — we can't introspect
        # arbitrary interfaces declaratively, but we can at least confirm
        # the host has LAN networking configured via the homelab module.
        {
          assertion = isMacvlan -> (config.homelab.network.enable or false);
          message = "nspawn.network.${name}: macvlan attachment requires homelab.network.enable = true on the host (so the LAN interface exists).";
        }
      ]) cfg);

    containers = lib.mapAttrs mkContainer cfg;
  };
}
