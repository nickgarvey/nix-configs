{ lib, ... }:
{
  disko.devices = {
    disk = {
      os = {
        device = "/dev/disk/by-id/nvme-NVMe_CA6-8D1024_0021235005SD";
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

    };
  };
}
