{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/lan-network.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/containers/frigate.nix
    ../../modules/containers/caddy-static.nix
    ../../modules/containers/garage.nix
    ../../modules/microvm/smb.nix
    ../../modules/nix-remote-builder-client.nix
    ../../modules/mlx-direct-peer.nix
  ];

  services.mlxDirectPeer.enable = true;

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "tarrasque";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZcTP3OJYZenl8bb9fC9NTIvFCOaxs2gi1Mz4OhAByw";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
  };

  services.icmpv6-archive.enable = true;

  homelab.network.enable = true;
  # Required so the garage container (on vmbr0) can route to its peer's
  # delegated /64 via the 25G mlx interface — crosses interfaces, needs
  # IPv6 forwarding.
  homelab.network.ipv6Forward = true;

  networking.hostName = "aboleth";

  sops.defaultSopsFile = ../../secrets/aboleth.yaml;
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
    # Aboleth's IPv6 lives in 2001:470:482f:200::/64 (delegated), not the
    # LAN /64 — suppress SLAAC so it doesn't autoconfig a LAN-/64 address.
    ipv6.suppressSlaac = true;
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
    bucketSupport = false;
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

  # --- Garage S3 (nspawn container, IPv6-only) ---
  fileSystems."/fast/garage" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@garage" "nofail" ];
  };
  nspawn.garage = {
    hostBridge = "vmbr0";
    localAddress6 = "2001:470:482f:200::2/64";
    hostBridgeAddress = "2001:470:482f:200::1";
    dataPath = "/fast/garage";
    hostname = "aboleth";
    capacity = "1T";
    replicationFactor = 2;
    peers = [ "90dd7a079aec5a9bead87277093390fbf4e66e018a946149af829cd85f875f0f@garage-tarrasque.home.arpa:3901" ];
  };

  # --- Frigate NVR (nspawn container) ---
  nspawn.frigate = {
    hostBridge = "vmbr0";
    localAddress = "10.28.12.109/16";
    dataPath = "/fast/frigate/data";
    cachePath = "/fast/frigate/cache";
  };
  networking.firewall.allowedTCPPorts = [ 2049 8443 ];

  # --- Static file server (nspawn container) ---
  nspawn.caddy-static.enable = true;

  environment.systemPackages = with pkgs; [
    ethtool
  ];

  system.stateVersion = "25.05";
}
