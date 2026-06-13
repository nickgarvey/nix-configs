{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/networkd.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/containers/frigate.nix
    ../../modules/containers/garage.nix
    ../../modules/microvm/smb.nix
    ../../modules/nix/nix-remote-builder-client.nix
    ../../modules/services/fancontrol.nix
  ];

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "talos";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZcTP3OJYZenl8bb9fC9NTIvFCOaxs2gi1Mz4OhAByw";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
  };

  services.icmpv6-archive.enable = true;

  homelab.network.enable = true;
  # Required so the garage container (on vmbr0) can route to its peer's
  # delegated /64 — crosses interfaces, needs IPv6 forwarding.
  homelab.network.ipv6Forward = true;

  networking.hostName = "lydia";

  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
    "split_lock_detect=off"
    # Let f71882fg claim the Fintek F81866A SIO @ 0x290 despite ACPI's
    # PNP0C02 reservation; required for fan tach/PWM control.
    "acpi_enforce_resources=lax"
  ];

  boot.kernelModules = [ "f71882fg" ];

  networking.nftables.enable = true;

  # Bridge for VMs/containers to get LAN access (IPv6 auto-derived from
  # lan-hosts.nix).
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp5s0";
    ipv4 = {
      address = "10.28.12.108/16";
      gateway = "10.28.0.1";
    };
    # lydia's own LAN identity is the static 2001:470:482f::6 (lan-hosts.nix).
    # suppressSlaac stops networkd adding a second, dynamic LAN-/64 address
    # on top of it.
    ipv6.suppressSlaac = true;
    # aboleth (garage container) lives in the delegated 2001:470:482f:200::/64.
    # Carry that /64's gateway on vmbr0 so the container's hostBridgeAddress
    # next-hop resolves and the router's on-link route for the /64
    # (modules/router/lan-ipv6.nix) NDP-resolves to us.
    ipv6.extraAddresses = [ "2001:470:482f:200::1/64" ];
  };
  # Tailscale
  services.tailscale.enable = true;

  # SATA mirror (2x 6TB WDC) — slow/bulk storage.
  fileSystems."/slow/backups" = {
    device = "/dev/disk/by-label/slow";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@backups" "nofail" ];
  };

  # Samsung 980 PRO NVMe — fast tier.
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

  # Pool btrfs roots (subvol=/) mounted for btrbk: snapshots must live on the
  # same filesystem as their source subvolume, and the mounted subvols
  # (/slow/backups etc.) can't hold sibling snapshot dirs.
  fileSystems."/mnt/slow-root" = {
    device = "/dev/disk/by-label/slow";
    fsType = "btrfs";
    options = [ "subvol=/" "nofail" ];
  };
  fileSystems."/mnt/fast-root" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "subvol=/" "nofail" ];
  };

  # btrbk snapshots
  services.btrbk.instances.data = {
    onCalendar = "hourly";
    settings = {
      snapshot_preserve_min = "2d";
      snapshot_preserve = "14d";
      volume."/mnt/slow-root" = {
        subvolume."@backups" = { snapshot_dir = ".snapshots"; };
      };
      volume."/mnt/fast-root" = {
        subvolume."@media" = { snapshot_dir = ".snapshots"; };
      };
    };
  };

  # btrbk does not create snapshot_dir itself.
  systemd.tmpfiles.rules = [
    "d /mnt/slow-root/.snapshots 0700 root root - -"
    "d /mnt/fast-root/.snapshots 0700 root root - -"
  ];

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

  nspawn.frigate = {
    hostBridge = "vmbr0";
    localAddress = "10.28.12.109/16";
    dataPath = "/fast/frigate/data";
    cachePath = "/fast/frigate/cache";
  };
  networking.firewall.allowedTCPPorts = [ 8443 ];

  environment.systemPackages = with pkgs; [
    ethtool
  ];

  system.stateVersion = "25.05";
}
