{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/k3s-hosts.nix
    ../../modules/containers/frigate.nix
    ../../modules/microvm/smb.nix
    ../../modules/windows-vm.nix
  ];

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
  ];

  # --- Networking ---
  # Bridge for VMs to get LAN access
  networking.bridges.vmbr0 = {
    interfaces = [ "enp0s31f6" ];
  };
  networking.interfaces.vmbr0 = {
    useDHCP = true;
  };
  # Disable offloading to match current Proxmox config
  systemd.services.disable-offloading = {
    description = "Disable TSO/GSO/GRO on enp0s31f6";
    after = [ "network-pre.target" ];
    wantedBy = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/bin/ethtool -K enp0s31f6 tso off gso off gro off";
    };
  };

  # Tailscale
  services.tailscale.enable = true;

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

  # --- SMB (microvm) ---
  microvm-smb = {
    hostBridge = "vmbr0";
    address = "10.28.12.110/16";
    gateway = "10.28.0.1";
    mac = "02:00:00:00:01:10";
    shares = [
      { name = "media"; path = "/fast/media"; owner = "media"; }
    ];
  };

  # --- Frigate NVR (nspawn container) ---
  nspawn.frigate = {
    hostBridge = "vmbr0";
    localAddress = "10.28.12.109/24";
    dataPath = "/fast/frigate/data";
    cachePath = "/fast/frigate/cache";
  };

  # --- Windows VM ---
  services.windowsVm = {
    enable = true;
    vmName = "windows-vpn";
    memory = 8000;
    vcpus = 2;
    diskPath = "/var/lib/libvirt/images/windows-vpn.qcow2";
    diskFormat = "qcow2";
    bridgeName = "vmbr0";
  };

  environment.systemPackages = with pkgs; [
    ethtool
  ];

  system.stateVersion = "25.05";
}
