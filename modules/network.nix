{ config, lib, ... }:

let
  cfg = config.homelab.network;

  inherit (import ./lan-hosts.nix) lanHosts;
  hostname = config.networking.hostName;
  hostEntry = lib.findFirst (h: h.hostname == hostname) null lanHosts;

  hasBridge = cfg.bridge != null;
  hasIPv6 = hostEntry != null && hostEntry.ipv6 != null && hostEntry.mac != "";
in
{
  options.homelab.network = {
    enable = lib.mkEnableOption "homelab network configuration";

    # Affects both IPv4 and IPv6 interface management
    useNetworkManager = lib.mkEnableOption "NetworkManager (for workstations/WiFi)";

    # IPv4 only — IPv6 forwarding is managed separately by the router module
    ipv4Forward = lib.mkEnableOption "IPv4 forwarding (required for k3s/MetalLB)";

    bridge = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Bridge device name.";
          };
          interface = lib.mkOption {
            type = lib.types.str;
            description = "Physical interface to enslave to the bridge.";
          };
          ipv4 = {
            address = lib.mkOption {
              type = lib.types.str;
              description = "Static IPv4 address in CIDR notation (e.g. \"10.28.12.108/16\").";
            };
            gateway = lib.mkOption {
              type = lib.types.str;
              description = "IPv4 default gateway (e.g. \"10.28.0.1\").";
            };
            dns = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "10.28.0.1" ];
              description = "IPv4 DNS servers.";
            };
          };
          # IPv6 is auto-derived from lan-hosts.nix and added to the bridge if available
        };
      });
      default = null;
      description = "Bridge with static IPv4. IPv6 is auto-added from lan-hosts.nix if available.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # --- Base: always systemd-networkd ---
    {
      networking.useNetworkd = true;
      networking.networkmanager.enable = lib.mkDefault cfg.useNetworkManager;
    }

    # --- IPv4 forwarding ---
    (lib.mkIf cfg.ipv4Forward {
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    })

    # --- Primary interface (no bridge, no NM) ---
    # networkd manages the ethernet directly:
    #   IPv4: DHCP from Kea on router (MAC-based reservation gives stable address)
    #   IPv6: static address from lan-hosts.nix
    (lib.mkIf (!hasBridge && !cfg.useNetworkManager && hasIPv6) {
      systemd.network.networks."25-static" = {
        matchConfig.MACAddress = hostEntry.mac;
        networkConfig.DHCP = "ipv4"; # IPv4 only — IPv6 is static below
        # Use MAC as client ID so Kea matches hw-address reservations
        dhcpV4Config.ClientIdentifier = "mac";
        address = [ "${hostEntry.ipv6}/64" ]; # IPv6 static
      };
    })

    # --- Bridge ---
    (lib.mkIf hasBridge (let br = cfg.bridge; in {
      systemd.network.netdevs."10-${br.name}" = {
        netdevConfig = {
          Name = br.name;
          Kind = "bridge";
        };
      };

      systemd.network.networks."10-${br.interface}" = {
        matchConfig.Name = br.interface;
        networkConfig.Bridge = br.name;
      };

      systemd.network.networks."10-${br.name}" = {
        matchConfig.Name = br.name;
        # IPv4: static address from bridge config
        address = [ br.ipv4.address ]
          # IPv6: auto-derived from lan-hosts.nix
          ++ lib.optionals hasIPv6 [ "${hostEntry.ipv6}/64" ];
        gateway = [ br.ipv4.gateway ];
        dns = br.ipv4.dns;
        networkConfig.DHCP = "no";
      };
    }))
  ]);
}
