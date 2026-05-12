# Workaround for a ConnectX-4 Lx firmware hang that happens on cold boot:
# the card occasionally fails to leave "pre-initializing" state, and the
# mlx5_core driver gives up after ~120s with -ETIMEDOUT. Removing the PCIe
# device and triggering a rescan kicks the firmware out of the stuck state;
# the second probe succeeds and the netdev appears.
#
# This unit runs before systemd-networkd so any networkd unit matching the
# mlx interface (e.g. 30-mlx-direct) can proceed normally after recovery.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mlxFirmwareRecovery;
in
{
  options.services.mlxFirmwareRecovery = {
    enable = lib.mkEnableOption "mlx5 PCIe firmware-hang auto-recovery";

    pciAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "0000:02:00.0" "0000:02:00.1" ];
      description = ''
        Full PCIe addresses (with domain) of the mlx5 functions to monitor.
        Get them from `lspci -D | grep -i mellanox`.
      '';
    };

    waitSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Seconds to wait for a netdev to appear after rescan.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.mlx-firmware-recovery = {
      description = "Recover hung mlx5 firmware via PCIe remove+rescan";
      before = [ "systemd-networkd.service" "network-pre.target" ];
      wantedBy = [ "systemd-networkd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -u
        for ADDR in ${lib.concatStringsSep " " cfg.pciAddresses}; do
          DEV=/sys/bus/pci/devices/$ADDR
          if [ ! -d "$DEV" ]; then
            echo "mlx-recover: $ADDR not present, skipping"
            continue
          fi
          if [ -d "$DEV/net" ] && [ -n "$(ls "$DEV/net" 2>/dev/null)" ]; then
            echo "mlx-recover: $ADDR healthy (netdev: $(ls "$DEV/net"))"
            continue
          fi
          echo "mlx-recover: $ADDR has no netdev — removing and rescanning"
          echo 1 > "$DEV/remove"
          sleep 1
          echo 1 > /sys/bus/pci/rescan
          for i in $(seq 1 ${toString cfg.waitSeconds}); do
            if [ -d "$DEV/net" ] && [ -n "$(ls "$DEV/net" 2>/dev/null)" ]; then
              echo "mlx-recover: $ADDR recovered after ''${i}s (netdev: $(ls "$DEV/net"))"
              break
            fi
            sleep 1
          done
          if [ ! -d "$DEV/net" ] || [ -z "$(ls "$DEV/net" 2>/dev/null)" ]; then
            echo "mlx-recover: $ADDR still missing netdev after ${toString cfg.waitSeconds}s — giving up"
          fi
        done
      '';
    };
  };
}
