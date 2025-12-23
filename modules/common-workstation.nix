{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./nixos-common.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # Audio
  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  # Enable Wayland for Chrome and VSCode
  environment.variables.NIXOS_OZONE_WL = "1";

  time.timeZone = "America/Los_Angeles";

  users.users.ngarvey = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "render" "dialout" "tty" ];
    packages = with pkgs; [
      atop
      code-cursor
      cursor-cli
      dig
      dmidecode
      efibootmgr
      gh
      ghostty
      google-chrome
      htop
      insync
      kubectl
      k9s
      mpv
      obsidian
      spotify
      wl-clipboard
    ];
  };

  networking.firewall = {
    allowedUDPPorts = [
      5353 # Spotify Connect
    ];
  };

  environment.systemPackages = with pkgs; [
  ] ++ config.commonConfig.commonPackages;

  # Display manager with COSMIC desktop
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "ngarvey";
    };
    sddm.enable = true;
    defaultSession = "cosmic";
  };

  services.desktopManager.cosmic = {
    enable = true;
  };

  services.xserver.enable = true;

  services.kanata = {
    enable = true;
    keyboards.keyboard = {
      configFile = ../configs/kanata-linux.cfg;
      extraDefCfg = "process-unmapped-keys yes";
    };
  };
}

