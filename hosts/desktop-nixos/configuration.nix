{ config, lib, pkgs, inputs, ... }:

let
  personal-nixpkgs = inputs.personal-nixpkgs.packages.${pkgs.system};

  disableGpu = import "${inputs.self}/lib/disable-gpu-overlay.nix" { inherit lib; };
  google-chrome-no-gpu = disableGpu {
    pkg = pkgs.google-chrome;
    desktopFilePath = "share/applications/google-chrome.desktop";
    execPath = "bin/google-chrome-stable";
  };

  obsidian-no-gpu = disableGpu {
    pkg = pkgs.obsidian;
    desktopFilePath = "share/applications/obsidian.desktop";
    execPath = "obsidian";
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/qmk.nix
    ../../modules/llm-services.nix
    ../../modules/nixpkgs-tracker.nix
  ];

  nixpkgs.overlays = [
    (import ../../overlays/whisper-cpp.nix)
  ];

  cursorRemoteNode.enable = true;

  services.vllm = {
    enable = true;
    model = "Qwen/Qwen3-14B-AWQ";
    gpuMemoryUtilization = "0.65";
    port = 28600;
    openFirewall = true;
  };

  services.nixpkgs-tracker.enable = true;

  networking = {
    hostName = "desktop-nixos";
    networkmanager.enable = true;
    hostId = "a4c946db";
  };

  nix.settings = {
    download-buffer-size = 524288000;
    max-jobs = 4;
    cores = 6;
  };

  nixpkgs.config.allowUnfree = true;
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
  };

  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  # Enable Wayland for Chrome and VSCode
  environment.variables.NIXOS_OZONE_WL = "1";


  time.timeZone = "America/Los_Angeles";

  users.users.ngarvey = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "render" "docker" "dialout" "tty" ];
    packages = with pkgs; [
      atop
      code-cursor
      cursor-cli
      dig
      dmidecode
      efibootmgr
      gh
      ghostty
      google-chrome-no-gpu
      htop
      insync
      keymapp
      kubectl
      k9s
      mpv
      nvidia-container-toolkit
      obsidian-no-gpu
      prismlauncher
      qemu
      spotify
      vscode.fhs
      wl-clipboard
      xca
    ];
  };

  programs.firefox = {
    enable = true;
    package = pkgs.firefox-bin;
    preferences = {
      "media.hardware-video-decoding.force-enabled" = true;
    };
  };

  networking.firewall = {
    allowedUDPPorts = [
      5353 # Spotify Connect
    ];
  };

  virtualisation = {
    docker = {
      enable = true;
      autoPrune.enable = true;
      enableOnBoot = true;
    };
  };

  environment.systemPackages = with pkgs; [
  ] ++ config.commonConfig.commonPackages;

  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "ngarvey";
    };
    sddm = {
      enable = true;
      # There is an nVidia driver race that causes the desktop to crash
      # on first load, so relogin
      autoLogin.relogin = true;
    };
    defaultSession = "cosmic";
  };

  services.desktopManager.cosmic = {
    enable = true;
  };

  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
  };

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
    keyboard.zsa.enable = true;
  };

  services.udev.packages = [
    # Disabled due to long tests during builds
    # pkgs.platformio-core
    pkgs.openocd
  ];

  services.kanata = {
    enable = true;
    keyboards.keyboard = {
      configFile = ../../configs/kanata-linux.cfg;
      extraDefCfg = "process-unmapped-keys yes";
    };
  };

  # Disable due to graphical glitches (nvidia?)
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  boot.supportedFilesystems = [ "zfs" ];

  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
    package = pkgs.steam.override {
      extraPkgs = pkgs: with pkgs; [
        python3
      ];
    };
  };

  programs.mosh.enable = true;
  services.tailscale.enable = false;

  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Do not change!
}
