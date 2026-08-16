{ lib, ... }:
# Both NVMe drives are WD_BLACK and can swap kernel enumeration order, so they
# are addressed by-id rather than by /dev/nvmeXn1.
#
# disko only formats during nixos-anywhere/disko-install, never on
# `nixos-rebuild` — adding subvolumes or mounts to `fast` later means creating
# them live as well as in this file.
{
  disko.devices = {
    disk = {
      os = {
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23433J800989";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            esp = {
              size = "512M";
              type = "EF00"; # EFI system partition
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            # 1 TiB root. The remaining ~836 GiB of the drive is deliberately
            # left unpartitioned, to be claimed once this host's role is settled.
            root = {
              size = "1024G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # Whole-disk btrfs scratch space. Formatted empty and left unmounted;
      # nothing on the host depends on it yet.
      fast = {
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25173X802585";
        type = "disk";
        content = {
          type = "btrfs";
          extraArgs = [ "-f" "-L" "fast" ];
        };
      };
    };
  };
}
