{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/steam.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "framework13-laptop";

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-routes"
      "--operator=ngarvey"
    ];
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  users.users.ngarvey.packages = with pkgs; [
    vlc
  ];

  systemd.sleep.extraConfig = ''
    AllowSuspend=yes
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  system.stateVersion = "25.11"; # Do not change!
}
