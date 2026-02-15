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

  services.tailscale = {
    enable = true;
    # Enable loose reverse path filtering for accepting routes
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-routes"
      "--operator=ngarvey"
    ];
  };

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
  };

  services.asusd = {
    enable = true;
    # user service had config issues
    enableUserService = false;
  };

  # Add control tools system-wide
  environment.systemPackages = with pkgs; [
    asusctl
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
    upower
  ];

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
