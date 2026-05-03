{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/lan-network.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/qmk.nix
    ../../modules/nrfconnect.nix
    ../../modules/steam.nix
    ../../modules/nix-binary-cache.nix
    ../../modules/whisper-gpu.nix
    ../../modules/containers/llama-cpp.nix
  ];

  services.icmpv6-archive.enable = true;

  homelab.network.enable = true;

  homelab.llama-cpp = {
    enable = true;
    backend = "cuda";
    models = [
      { name = "qwen3.6-27b"; repo = "unsloth/Qwen3.6-27B-GGUF"; filter = "UD-Q4_K_XL"; }
    ];
  };

  networking = {
    hostName = "desktop-nixos";
    hostId = "a4c946db";
  };

  nix.settings = {
    download-buffer-size = 524288000;
    max-jobs = 4;
    cores = 0;
  };

  # Auto-reboot if the box wedges while unattended (last hang lasted 3 days).
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10min";
  };

  zramSwap.enable = true;

  services.nixBinaryCache = {
    enable = true;
    signingKeySopsFile = ../../secrets/nix-builder.yaml;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvgPFo276pFe75SimIDp5JwKrIhSzD+ypRzt4GArzZ nix-builder"
    ];
  };

  nixpkgs.config.cudaSupport = true;

  boot = {
    binfmt.emulatedSystems = [ "aarch64-linux" ];

    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    blacklistedKernelModules = [ "r8169" "amdgpu" ];

    extraModulePackages = with config.boot.kernelPackages; [ r8125 ];
    kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" "r8125" "nvidia" "nvidia_drm" "nvidia_uvm" "nvidia_modeset" ];
    kernelParams = [
      "iommu=pt"
      "vfio-pci.ids=1002:13c0,1002:1640,1022:1649,1022:15b6,1022:15b7,1022:15e3"
      "pcie_aspm=off"
    ];

    kernel.sysctl = {
      "net.ipv6.conf.all.forwarding" = 1;
      "kernel.panic" = 10;
    };

  };

  users.users.ngarvey.packages = with pkgs; [
    nvidia-container-toolkit
    rsync
    xca
    remmina
    moonlight-qt
    insync
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
      nvidiaPersistenced = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
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
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Do not change!
}
