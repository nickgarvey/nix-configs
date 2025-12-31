{ lib, ... }:
{
  disko.devices = {
    disk = {
      os = {
        device = "/dev/nvme0n1";
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
            root = {
              size = "400G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
            local-storage = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/rancher/k3s/storage";
              };
            };
          };
        };
      };
    };
  };
}
