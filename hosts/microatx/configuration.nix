{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/lan-network.nix
    ../../modules/containers/frigate.nix
    ../../modules/microvm/smb.nix
  ];

  homelab.network.enable = true;

  networking.hostName = "microatx";

  sops.defaultSopsFile = ../../secrets/microatx.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  # --- Boot ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
    "split_lock_detect=off"
  ];

  networking.nftables.enable = true;

  # --- Networking ---
  # Bridge for VMs/containers to get LAN access (IPv6 auto-derived from lan-hosts.nix)
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp5s0";
    ipv4 = {
      address = "10.28.12.108/16";
      gateway = "10.28.0.1";
    };
  };
  # Incus loads br_netfilter which causes bridge traffic (including ARP) to
  # pass through netfilter, breaking DHCP and host connectivity on vmbr0.
  # Disable bridge netfilter since we use vmbr0 directly, not an Incus NAT bridge.
  networking.firewall.trustedInterfaces = [ "vmbr0" ];
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 0;
    "net.bridge.bridge-nf-call-ip6tables" = 0;
    "net.bridge.bridge-nf-call-arptables" = 0;
  };


  # Tailscale
  services.tailscale.enable = true;

  # --- NFS server (Longhorn backup target) ---
  services.nfs.server = {
    enable = true;
    exports = ''
      /slow/backups/longhorn 2001:470:482f::/48(rw,sync,no_subtree_check,no_root_squash)
    '';
  };
  # --- Storage: btrfs ---
  # SATA mirror (2x 8TB Seagate) — slow/bulk storage
  fileSystems."/slow/backups" = {
    device = "/dev/disk/by-label/slow";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@backups" "nofail" ];
  };

  # Samsung 980 PRO NVMe — fast tier
  fileSystems."/fast/media" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "subvol=@media" "nofail" ];
  };
  fileSystems."/fast/frigate" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@frigate" "nofail" ];
  };
  fileSystems."/fast/incus" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "subvol=@incus" "nofail" ];
  };
  fileSystems."/fast/longhorn" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@longhorn" "nofail" ];
  };

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/fast/media" "/fast/frigate" ];
  };

  # btrbk snapshots
  services.btrbk.instances.data = {
    onCalendar = "hourly";
    settings = {
      snapshot_preserve_min = "2d";
      snapshot_preserve = "14d";
      volume."/slow" = {
        subvolume.backups = { snapshot_dir = ".snapshots"; };
      };
      volume."/fast" = {
        subvolume.media = { snapshot_dir = ".snapshots"; };
      };
    };
  };

  # --- Incus ---
  users.users.ngarvey.extraGroups = [ "incus-admin" ];
  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    preseed = {
      config = {
        "core.https_address" = ":8443";
      };
      storage_pools = [
        {
          name = "default";
          driver = "btrfs";
          config = {
            source = "/fast/incus";
          };
        }
      ];
    };
  };

  # Longhorn NFS backup directory
  systemd.tmpfiles.rules = [
    "d /slow/backups/longhorn 0755 root root - -"
  ];

  # --- SMB (microvm) ---
  microvm-smb = {
    hostBridge = "vmbr0";
    address = "10.28.12.110/16";
    gateway = "10.28.0.1";
    ipv6Address = "2001:470:482f::14/64";
    ipv6Gateway = "2001:470:482f::1";
    mac = "02:00:00:00:01:10";
    shares = [
      { name = "media"; path = "/fast/media"; owner = "media"; }
    ];
  };

  # --- Frigate NVR (nspawn container) ---
  nspawn.frigate = {
    hostBridge = "vmbr0";
    localAddress = "10.28.12.109/16";
    dataPath = "/fast/frigate/data";
    cachePath = "/fast/frigate/cache";
  };
  networking.firewall.allowedTCPPorts = [ 2049 8443 ];

  environment.systemPackages = with pkgs; [
    ethtool
  ];

  system.stateVersion = "25.05";
}
