{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/qmk.nix
    ../../modules/steam.nix
    ../../modules/nixpkgs-tracker.nix
    ../../modules/k3s-hosts.nix
  ];

  nixpkgs.overlays = [
    (import ../../overlays/whisper-cpp.nix)
  ];

  cursorRemoteNode.enable = true;

  services.nixpkgs-tracker.enable = true;

  networking = {
    hostName = "desktop-nixos";
    hostId = "a4c946db";
  };

  nix.settings = {
    download-buffer-size = 524288000;
    max-jobs = 4;
    cores = 6;
  };

  nixpkgs.config.cudaSupport = true;

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    loader.efi.efiSysMountPoint = "/efi";

    blacklistedKernelModules = [ "r8169" "amdgpu" ];

    extraModulePackages = with config.boot.kernelPackages; [ r8125 ];
    kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" "r8125" "nvidia" "nvidia_drm" "nvidia_uvm" "nvidia_modeset" ];
    kernelParams = [
      "iommu=pt"
      "vfio-pci.ids=1002:13c0,1002:1640,1022:1649,1022:15b6,1022:15b7,1022:15e3"
    ];

    kernel.sysctl = {
      "net.ipv6.conf.all.forwarding" = 1;
    };

    supportedFilesystems = [ "zfs" ];
    # zfs.package = config.boot.kernelPackages.zfs_2_4;
    zfs.forceImportRoot = false;
    zfs.forceImportAll = false;
  };

  # Docker virtualization
  virtualisation = {
    docker = {
      enable = true;
      autoPrune.enable = true;
      enableOnBoot = true;
    };
  };
  users.users.ngarvey.extraGroups = [ "docker" ];

  users.users.ngarvey.packages = with pkgs; [
    claude-code
    nvidia-container-toolkit
    qemu
    rsync
    xca
    zfs
  ];

  services.xserver.videoDrivers = [ "nvidia" ];

  # Allow NVIDIA to initialize without a connected monitor
  services.xserver.deviceSection = ''
    Option "AllowEmptyInitialConfiguration"
  '';

  hardware = {
    nvidia = {
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = false;
      open = true;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.latest;
    };
    nvidia-container-toolkit.enable = true;
  };

  services.udev.packages = [
    pkgs.openocd
  ];

  # Enable autologin
  services.displayManager.autoLogin = {
    enable = true;
    user = "ngarvey";
  };

  # Disable due to graphical glitches (nvidia?)
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  # Flatpak
  services.flatpak.enable = true;

  # XDG Portals for Flatpak desktop integration
  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-cosmic
      pkgs.xdg-desktop-portal-gtk
    ];
    config.common.default = [ "cosmic" "gtk" ];
  };

  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Do not change!
}
