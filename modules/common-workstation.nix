{ config, lib, pkgs, inputs, ... }:

let
  helium-browser = pkgs.callPackage ../pkgs/helium-browser {
    helium-browser-pkg = inputs.helium-browser.packages.${pkgs.system}.default;
  };
in
{
  imports = [
    ./nixos-common.nix
    ./smb-automount.nix
    inputs.sops-nix.nixosModules.sops
  ];

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  nixpkgs.config.allowUnfree = true;

  # Wrap Chrome to always pass --hide-crash-restore-bubble
  nixpkgs.overlays = [
    (self: super: {
      google-chrome = super.google-chrome.override {
        commandLineArgs = "--hide-crash-restore-bubble";
      };
    })
  ];

  # Audio
  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  # Enable Wayland for Chrome and VSCode
  environment.variables.NIXOS_OZONE_WL = "1";

  time.timeZone = "America/Los_Angeles";

  users.users.ngarvey = {
    uid = 1000;
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "render" "dialout" "tty" "input" ];
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
      helium-browser
      htop
      k9s
      kubectl
      libnotify
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
    # Disable firewall logging to prevent dmesg spam from port scans
    logRefusedConnections = false;
  };

  environment.systemPackages = with pkgs; [
  ] ++ config.commonConfig.commonPackages;

  # COSMIC display manager and desktop
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic = {
    enable = true;
  };

  services.xserver.enable = true;
  programs.firefox.enable = true;

  services.kanata = {
    enable = true;
    keyboards.keyboard = {
      configFile = ../configs/kanata-linux.cfg;
      extraDefCfg = "process-unmapped-keys yes";
    };
  };
}

