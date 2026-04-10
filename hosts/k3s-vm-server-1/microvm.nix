{ config, lib, pkgs, ... }:
# Hardware/microvm options for k3s-vm-server-1.
#
# Imported by both:
#   - the top-level nixosConfigurations.k3s-vm-server-1 (so deploy.py works)
#   - hosts/microatx/configuration.nix microvm.vms.k3s-vm-server-1 (declarative VM)
{
  nixpkgs.hostPlatform = "x86_64-linux";

  microvm = {
    hypervisor = "qemu";

    vcpu = 5;
    mem = 32768; # 32 GiB

    writableStoreOverlay = "/nix/.rw-store";

    interfaces = [{
      type = "tap";
      id = "vm-ks1";
      mac = "02:00:00:00:02:01"; # must match modules/lan-hosts.nix entry
    }];

    volumes = [
      {
        image = "/var/lib/microvms/k3s-vm-server-1/var.img";
        mountPoint = "/var";
        label = "k3s-var";
        size = 51200; # 50 GiB
        fsType = "ext4";
      }
      {
        image = "/var/lib/microvms/k3s-vm-server-1/rw-store.img";
        mountPoint = "/nix/.rw-store";
        label = "k3s-rw-store";
        size = 30720; # 30 GiB
        fsType = "ext4";
      }
      {
        image = "/fast/longhorn/k3s-vm-server-1/longhorn.img";
        mountPoint = "/var/lib/longhorn";
        label = "k3s-longhorn";
        size = 307200; # 300 GiB
        fsType = "ext4";
      }
    ];

    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
      {
        source = "/var/lib/microvms/k3s-vm-server-1/sops";
        mountPoint = "/run/sops-age";
        tag = "sops-age";
        proto = "virtiofs";
      }
    ];
  };

  fileSystems."/nix/store".fsType = lib.mkDefault "none";

  nix.optimise.automatic = lib.mkForce false;

  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;

  fileSystems."/run/sops-age".neededForBoot = lib.mkForce true;

  sops.age.keyFile = lib.mkForce "/run/sops-age/keys.txt";
}
