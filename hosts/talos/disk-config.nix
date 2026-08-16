{ lib, ... }:
# Small OS disk holds /boot and /; the 4TB carries the bulk filesystems as
# btrfs subvolumes.
{
  disko.devices = {
    disk = {
      bootKingston = {
        device = "/dev/disk/by-id/nvme-KINGSTON_SNV2S500G_50026B768610E7B8";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            esp = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # Adding a subvolume later takes two steps: declare it here, and create
      # it live with `btrfs subvolume create` — `nixos-rebuild` never re-runs
      # disko's format mode.
      data4tb = {
        device = "/dev/disk/by-id/nvme-CT4000T705SSD3_2506E9A5D504";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-L" "data4" "-f" ];
                subvolumes = {
                  "@nix"  = { mountpoint = "/nix";  mountOptions = [ "noatime" ]; };
                  "@home" = { mountpoint = "/home"; mountOptions = [ "noatime" ]; };
                  "@var"  = { mountpoint = "/var";  mountOptions = [ "noatime" ]; };
                };
              };
            };
          };
        };
      };
    };
  };
}
