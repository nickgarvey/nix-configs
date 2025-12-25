{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio-mirroring.nix
    ../../modules/common-workstation.nix
    ../../modules/steam.nix
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Kernel parameters for brightness control
  boot.kernelParams = [ "i915.enable_dpcd_backlight=1" ];
  # Use latest kernel to get UCSI deadlock fixes
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelModules = [ "nvidia" "nvidia_drm" "nvidia_uvm" "nvidia_modeset" ];

  networking.hostName = "g16-laptop";

  services.tailscale = {
    enable = true;
    # Enable loose reverse path filtering for accepting routes
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-routes"
      "--operator=ngarvey"
    ];
  };

  nixpkgs.config.cudaSupport = true;

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    nvidia = {
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = false;
      open = true;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.latest;
    };
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  # ASUS GPU switching service - allows switching between GPU modes
  # Use 'supergfxctl -m integrated' to switch to integrated-only mode
  # Use 'supergfxctl -m hybrid' to switch back to hybrid mode
  # You may need to log out and back in after switching
  services.supergfxd.enable = true;

  services.asusd = {
    enable = true;
    # user service had config issues
    enableUserService = false;
  };

  # Add GPU control tools system-wide
  environment.systemPackages = with pkgs; [
    supergfxctl
    asusctl
    config.hardware.nvidia.package
    # GPU switching scripts
    (pkgs.writeShellApplication {
      name = "gpu-integrated";
      text = builtins.readFile ./bin/gpu-integrated;
    })
    (pkgs.writeShellApplication {
      name = "gpu-hybrid";
      text = builtins.readFile ./bin/gpu-hybrid;
    })
    (pkgs.writeShellApplication {
      name = "gpu-status";
      text = builtins.readFile ./bin/gpu-status;
    })
    # Exit node switching scripts
    (pkgs.writeShellApplication {
      name = "exitnode-on";
      runtimeInputs = [ pkgs.tailscale ];
      text = builtins.readFile ./bin/exitnode-on;
    })
    (pkgs.writeShellApplication {
      name = "exitnode-off";
      runtimeInputs = [ pkgs.tailscale ];
      text = builtins.readFile ./bin/exitnode-off;
    })
    (pkgs.writeShellApplication {
      name = "exitnode-status";
      runtimeInputs = [ pkgs.tailscale pkgs.jq ];
      text = builtins.readFile ./bin/exitnode-status;
    })
  ];

  users.users.ngarvey.packages = with pkgs; [
    vlc
  ];

  services.displayManager.gdm.enable = true;

  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  # GPU Underclocking Service - Moderate Profile
  # Applies moderate underclocking on boot for better power efficiency:
  #   - Power limit: 65W (reduced from 125W max, ~20-25% power savings)
  #   - GPU clock offset: -250 MHz (target ~2855 MHz max, ~8% performance impact)
  #   - Memory clock offset: -750 MHz (target ~8250 MHz max)
  systemd.services.nvidia-gpu-underclock = {
    description = "Apply NVIDIA GPU moderate underclocking settings";
    wantedBy = [ "multi-user.target" ];
    after = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Wait for NVIDIA driver to be ready
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
    };
    script = ''
      # Enable persistence mode for clock settings to persist
      ${config.boot.kernelPackages.nvidiaPackages.latest.bin}/bin/nvidia-smi -pm 1 || true

      # Set power limit to 65W (moderate underclock)
      ${config.boot.kernelPackages.nvidiaPackages.latest.bin}/bin/nvidia-smi -pl 65 || true

      # Lock GPU clock to target frequency (using supported clock value)
      ${config.boot.kernelPackages.nvidiaPackages.latest.bin}/bin/nvidia-smi -lgc 2850,2850 || true

      # Underclock memory to 8250 MHz (9001 - 750 = 8251, rounded to 8250 MHz)
      ${config.boot.kernelPackages.nvidiaPackages.latest.bin}/bin/nvidia-smi -lmc 8250,8250 || true
    '';
  };

  system.stateVersion = "25.11"; # Do not change!
}
