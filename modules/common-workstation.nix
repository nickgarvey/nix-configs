{ config, lib, pkgs, inputs, ... }:

let
  helium-browser = pkgs.callPackage ../pkgs/helium-browser {
    helium-browser-pkg = inputs.helium-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };
  claude-code = inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  anki-with-sync = pkgs.symlinkJoin {
    name = "anki-with-sync";
    paths = [ (pkgs.anki.withAddons (with pkgs.ankiAddons; [ anki-connect ])) ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/anki \
        --set SYNC_ENDPOINT https://anki-sync-server.bigeye-turtle.ts.net/
    '';
  };
in
{
  imports = [
    ./nixos-common.nix
    ./pico-udev.nix
    ./smb-automount.nix
    inputs.sops-nix.nixosModules.sops
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  nixpkgs.config.allowUnfree = true;

  # Wrap Chrome to always pass --hide-crash-restore-bubble
  nixpkgs.overlays = [
    (self: super: {
      google-chrome = super.google-chrome.override {
        commandLineArgs = "--hide-crash-restore-bubble";
      };
      cosmic-comp = super.cosmic-comp.overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          ../patches/cosmic-comp-reduce-tiling-latency.patch
        ];
      });
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
    extraGroups = [ "wheel" "networkmanager" "render" "dialout" "tty" "input" "docker" ];
    packages = with pkgs; [
      anki-with-sync
      atop
      claude-code
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
      incus
      k9s
      kubectl
      libnotify
      mpv
      obsidian
      spotify
      virt-viewer
      wl-clipboard
    ];
  };

  # resolved handles split-DNS: Tailscale pushes its nameservers for ts.net
  # domains, while DHCP-provided DNS is used for everything else.
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "false";
  };
  networking.networkmanager.dns = "systemd-resolved";

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-dns"
      "--operator=ngarvey"
    ];
  };

  networking.firewall = {
    allowedUDPPorts = [
      5353 # Spotify Connect
    ];
    # Disable firewall logging to prevent dmesg spam from port scans
    logRefusedConnections = false;
  };

  # COSMIC display manager and desktop
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;

  services.xserver.enable = true;

  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    enableOnBoot = true;
  };

  services.kanata = {
    enable = true;
    keyboards.keyboard = {
      configFile = ../configs/kanata-linux.cfg;
      extraDefCfg = "process-unmapped-keys yes";
    };
  };
}

