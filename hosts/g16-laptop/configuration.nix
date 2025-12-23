{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/steam.nix
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Load NVIDIA kernel modules
  boot.kernelModules = [ "nvidia" "nvidia_drm" "nvidia_uvm" "nvidia_modeset" ];

  networking.hostName = "g16-laptop";

  # NVIDIA GPU Configuration
  nixpkgs.config.cudaSupport = true;

  hardware = {
    nvidia = {
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = false;
      open = true;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.latest;
    };
  };

  # Configure X server to use NVIDIA driver
  services.xserver.videoDrivers = [ "nvidia" ];

  # Enable SuperGFXctl for ASUS GPU switching
  # This allows switching between Integrated, Hybrid, and Dedicated GPU modes
  # Use `supergfxctl -m <mode>` to switch modes at runtime
  services.supergfxd = {
    enable = true;
  };

  # Add GPU control tools system-wide
  # Note: nvidia-settings is included via hardware.nvidia.nvidiaSettings = true
  environment.systemPackages = with pkgs; [
    supergfxctl
    config.hardware.nvidia.package
  ];

  # Disable sleep and hibernate
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  system.stateVersion = "25.11"; # Do not change!
}
