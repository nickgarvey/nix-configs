{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/k3s-hosts.nix
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

  # Coral Edge TPU (disabled with Frigate)
  # boot.extraModulePackages = with config.boot.kernelPackages; [ gasket ];
  # boot.kernelModules = [ "apex" ];
  # services.udev.extraRules = ''
  #   SUBSYSTEM=="apex", MODE="0660", GROUP="docker"
  # '';

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

  # --- Users/groups for SMB ---
  users.groups.media = {};
  users.users.media-ro = {
    isSystemUser = true;
    group = "media";
    home = "/var/empty";
  };

  # --- SMB shares ---
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "server string" = "microatx";
        security = "user";
        "map to guest" = "Bad User";
      };
      media = {
        path = "/fast/media";
        "read only" = "yes";
        browseable = "yes";
        "guest ok" = "yes";
        "force user" = "media-ro";
        "force group" = "media";
      };
      media-rw = {
        path = "/fast/media";
        "read only" = "no";
        browseable = "yes";
        "valid users" = "ngarvey";
      };
      backups = {
        path = "/slow/backups";
        "read only" = "no";
        browseable = "yes";
        "valid users" = "ngarvey";
      };
    };
  };

  # --- Docker + Frigate (disabled) ---
  # virtualisation.docker = {
  #   enable = true;
  #   autoPrune.enable = true;
  #   enableOnBoot = true;
  # };
  # users.users.ngarvey.extraGroups = [ "docker" ];

  # sops.secrets."frigate_rtsp_password_env" = {};

  # virtualisation.oci-containers.containers.frigate = {
  #   image = "ghcr.io/blakeblackshear/frigate:stable";
  #   ports = [
  #     "8971:8971"
  #     "5000:5000"
  #     "8554:8554"
  #     "8555:8555/tcp"
  #     "8555:8555/udp"
  #   ];
  #   volumes = [
  #     "/etc/localtime:/etc/localtime:ro"
  #     "/var/lib/frigate/config:/config"
  #     "/fast/frigate:/media/frigate"
  #   ];
  #   environment = {
  #     FRIGATE_RTSP_USER = "camera";
  #   };
  #   environmentFiles = [ config.sops.secrets."frigate_rtsp_password_env".path ];
  #   # TODO: check if --privileged is actually needed or if --device + --cap-add suffice
  #   extraOptions = [
  #     "--device=/dev/apex_0:/dev/apex_0"
  #     "--shm-size=512m"
  #     "--privileged"
  #   ];
  # };

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
