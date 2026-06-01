{ lib, ... }:
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

      # 2TB SN850X intentionally NOT declared — left as the staging btrfs
      # (passive backup of pre-migration state). Will be added in a
      # separate change when ready to use.

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
