{ config, lib, pkgs, ... }:

let
  cfg = config.nspawn.frigate;
in
{
  options.nspawn.frigate = {
    localAddress = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 address with prefix length for the frigate container (e.g. \"10.28.12.109/24\").";
    };

    localAddress6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "IPv6 address with prefix length for the frigate container.";
    };

    hostBridge = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge interface for the container network.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = "Host path for persistent frigate data.";
    };

    cachePath = lib.mkOption {
      type = lib.types.str;
      description = "Host path for frigate cache.";
    };
  };

  config = {
    # Coral Edge TPU (host loads modules for nspawn container)
    boot.extraModulePackages = with config.boot.kernelPackages; [ gasket ];
    boot.kernelModules = [ "apex" ];
    services.udev.extraRules = ''
      SUBSYSTEM=="apex", MODE="0660", GROUP="root"
    '';

    containers.frigate = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.localAddress;
      localAddress6 = lib.mkIf (cfg.localAddress6 != null) cfg.localAddress6;

      bindMounts = {
        "/var/lib/frigate" = {
          hostPath = cfg.dataPath;
          isReadOnly = false;
        };
        "/var/cache/frigate" = {
          hostPath = cfg.cachePath;
          isReadOnly = false;
        };
      };

      allowedDevices = [
        { node = "/dev/apex_0"; modifier = "rwm"; }
      ];
      extraFlags = [ "--bind=/dev/apex_0" ];

      config = { config, pkgs, lib, ... }: {
        # Coral modules are loaded on the host; suppress inside container
        boot.extraModulePackages = lib.mkForce [];

        # Fix /dev/apex_0 permissions (udev doesn't trigger for bind-mounted devices)
        systemd.services.frigate.serviceConfig.ExecStartPre = lib.mkBefore [
          "+${pkgs.coreutils}/bin/chown root:coral /dev/apex_0"
          "+${pkgs.coreutils}/bin/chmod 660 /dev/apex_0"
        ];

        services.frigate = {
          enable = true;
          hostname = "frigate";
          settings = {
            mqtt.enabled = false;
            detectors.coral = {
              type = "edgetpu";
              device = "pci";
            };
            cameras = {};
          };
        };

        networking = {
          defaultGateway = "10.28.0.1";
          firewall.enable = false;
        };

        system.stateVersion = "25.05";
      };
    };
  };
}
