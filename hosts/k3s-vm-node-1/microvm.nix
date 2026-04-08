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

    interfaces = [{
      type = "tap";
      id = "vm-k3s1";
      mac = "02:00:00:00:01:20"; # must match modules/lan-hosts.nix entry
    }];

    # Persistent /var: holds k3s state, containerd images, journal, sshd host
    # keys. Auto-created on first boot at the path below on microatx.
    volumes = [{
      image = "/var/lib/microvms/k3s-vm-node-1/var.img";
      mountPoint = "/var";
      label = "k3s-var";
      size = 102400; # 100 GiB
      fsType = "ext4";
    }];

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

  # The sops-age virtiofs share must be mounted *in initrd* (before
  # nixos-activation runs sops-install-secrets), otherwise the secret
  # decryption step fails and k3s never gets its cluster_token.
  fileSystems."/run/sops-age".neededForBoot = lib.mkForce true;

  # Override k3s-common.nix's default key path to read directly from the
  # virtiofs share — there's no opportunity to symlink it before activation.
  sops.age.keyFile = lib.mkForce "/run/sops-age/keys.txt";
}
