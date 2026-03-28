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

  networking.hostName = "g16-laptop";

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
  };

  services.asusd = {
    enable = true;
  };

  environment.systemPackages = with pkgs; [
    asusctl
    upower
  ];

  users.users.ngarvey.packages = with pkgs; [
    vlc
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  system.stateVersion = "25.11"; # Do not change!
}
