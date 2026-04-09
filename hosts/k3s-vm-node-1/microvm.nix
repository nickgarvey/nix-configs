{ config, lib, pkgs, ... }:
# Hardware/microvm options for k3s-vm-node-1.
#
# Note: nixpkgs.hostPlatform is set here so this module is self-sufficient
# when imported by the top-level nixosConfigurations.k3s-vm-node-1 entry.
# Imported by both:
#   - the top-level nixosConfigurations.k3s-vm-node-1 (so deploy.py works)
#   - hosts/microatx/configuration.nix microvm.vms.k3s-vm-node-1 (declarative VM)
{
  nixpkgs.hostPlatform = "x86_64-linux";

  microvm = {
    hypervisor = "qemu";

    # Host has 16 cores and 125 GiB RAM. No cgroup CPU cap is applied to qemu
    # vCPU threads, so giving the VM all 16 vCPUs is the "uncapped" equivalent.
    vcpu = 16;
    mem = 49152; # 48 GiB

    # Writable /nix/store overlay so the guest can accept closures pushed
    # by deploy.py independently of microatx. Backing volume is declared
    # below. See the long comment on the rw-store volume for the fallback.
    writableStoreOverlay = "/nix/.rw-store";

    interfaces = [{
      type = "tap";
      id = "vm-k3s1";
      mac = "02:00:00:00:01:20"; # must match modules/lan-hosts.nix entry
    }];

    # Persistent /var: holds k3s state, containerd images, journal, sshd host
    # keys. Auto-created on first boot at the path below on microatx.
    volumes = [
      {
        image = "/var/lib/microvms/k3s-vm-node-1/var.img";
        mountPoint = "/var";
        label = "k3s-var";
        size = 102400; # 100 GiB
        fsType = "ext4";
      }
      # Writable /nix/store overlay upperdir. Lets `deploy.py k3s-vm-node-1`
      # push closures directly into the guest without touching microatx's
      # store, making the VM largely independent of the host.
      #
      # If this combination (RO virtiofs store share + writable overlay)
      # causes boot problems — see microvm-nix/microvm.nix#43 and #210 —
      # fall back to a self-contained store by:
      #   1. Removing writableStoreOverlay and this volume.
      #   2. Removing the /nix/store virtiofs share below.
      #   3. Setting microvm.storeOnDisk = true (builds a dedicated store
      #      image at host-rebuild time; slower boot, more disk, but no
      #      overlay sharp edges).
      {
        image = "/var/lib/microvms/k3s-vm-node-1/rw-store.img";
        mountPoint = "/nix/.rw-store";
        label = "k3s-rw-store";
        size = 51200; # 50 GiB
        fsType = "ext4";
      }
    ];

    # Read-only /nix/store from the host plus the sops age key bind-mount.
    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
      {
        # Provisioned out-of-band on microatx — see plan.
        source = "/var/lib/microvms/k3s-vm-node-1/sops";
        mountPoint = "/run/sops-age";
        tag = "sops-age";
        proto = "virtiofs";
      }
    ];
  };

  # microvm.nix bind-mounts /nix/store from /nix/.ro-store without an
  # fsType; current nixpkgs requires one on every fileSystems entry.
  fileSystems."/nix/store".fsType = lib.mkDefault "none";

  # Incompatible with writableStoreOverlay — the overlay's upperdir would
  # fight with nix-store --optimise hardlinking.
  nix.optimise.automatic = lib.mkForce false;

  # microvm.nix direct-boots the kernel via qemu; there's no ESP and no
  # bootloader to install. k3s-common.nix enables systemd-boot for the
  # bare-metal k3s nodes, so turn it off here.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;

  # The sops-age virtiofs share must be mounted *in initrd* (before
  # nixos-activation runs sops-install-secrets), otherwise the secret
  # decryption step fails and k3s never gets its cluster_token.
  fileSystems."/run/sops-age".neededForBoot = lib.mkForce true;

  # Override k3s-common.nix's default key path to read directly from the
  # virtiofs share — there's no opportunity to symlink it before activation.
  sops.age.keyFile = lib.mkForce "/run/sops-age/keys.txt";
}
