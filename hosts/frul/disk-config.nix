{ lib, ... }:
# 512GB OS disk holds /boot and /. The 4TB NVMe is deliberately absent: it is
# used whole, as a raw device, by this node's Ceph OSD (modules/services/ceph.nix).
{
  disko.devices = {
    disk = {
      os = {
        # The 512GB is a YMTC UFS device on the chipset SCSI controller, and it
        # reports ID_SERIAL=2 — so by-id degrades to a useless "scsi-2" and
        # by-path is the only stable handle. LUN 0 is the 476.7GiB data LUN;
        # LUNs 1 and 2 are 4MiB UFS boot LUNs and must be left alone.
        device = "/dev/disk/by-path/pci-0000:00:17.0-scsi-0:0:0:0";
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
