{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/nixos-common.nix
    ../../modules/lan-network.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "skyforge";

  # We dd the image directly; no need to spend build time on zstd compression.
  sdImage.compressImage = false;

  # Cross-compile the whole closure: buildPlatform x86_64 → hostPlatform
  # aarch64 (set in hardware-configuration.nix). Most of nixpkgs cross-builds
  # cleanly; the kernel is the big win. If a specific package fails to cross,
  # override it back to emulated with a per-package overlay:
  #   nixpkgs.overlays = [(final: prev: {
  #     # forces foo to build via binfmt instead of cross
  #     foo = (final.pkgsBuildBuild.callPackage (prev.path + "/pkgs/.../foo") {});
  #   })];
  # Cross-compile JUST the kernel (the long pole). Everything else stays on
  # binfmt emulation. Whole-closure cross (nixpkgs.buildPlatform = x86)
  # works for many packages but breaks parade-of-fails on Go (git-lfs -m64),
  # Lua-codegen at build time (neovim), and probably more — for one printer
  # host the constant overrides aren't worth it.
  #
  # nvmd's raspberry-pi-5/default.nix sets boot.kernelPackages from its own
  # flake outputs (`nixos-raspberrypi.packages.aarch64-linux.linuxPackages_rpi5`),
  # so even mkForce'ing pkgs.linuxPackages_rpi5 from a native context still
  # gives a native kernel. We sidestep entirely: re-import nvmd's nixpkgs
  # with crossSystem set and reapply nvmd's overlays, then use that one
  # package. Adds one extra nixpkgs eval but only this drv is affected.
  boot.kernelPackages = let
    crossPkgs = import inputs.nixos-raspberrypi.inputs.nixpkgs {
      localSystem = "x86_64-linux";
      crossSystem = "aarch64-linux";
      overlays = with inputs.nixos-raspberrypi.overlays; [
        bootloader
        vendor-kernel
        vendor-firmware
        kernel-and-firmware
        vendor-pkgs
      ];
    };
  in lib.mkForce crossPkgs.linuxPackages_rpi5;

  # WiFi link: wpa_supplicant handles WPA association on wlan0.
  # IP layer: lan-network.nix matches wlan0 by MAC (from lan-hosts.nix) and
  # applies DHCPv4 + static IPv6 via systemd-networkd. The two layers
  # compose cleanly because wpa_supplicant only touches link, not IP.
  #
  # SSID and PSK both come from sops. networking.wireless.secretsFile only
  # supports substitution in PSK/auth fields (via `ext:`), not the SSID,
  # so we render the whole network block via sops.templates and load it
  # with extraConfigFiles.
  sops.secrets.wifi_ssid.sopsFile = ../../secrets/wifi.yaml;
  sops.secrets.wifi_psk.sopsFile = ../../secrets/wifi.yaml;

  sops.templates."wpa_supplicant-home.conf" = {
    content = ''
      network={
        ssid="${config.sops.placeholder.wifi_ssid}"
        psk="${config.sops.placeholder.wifi_psk}"
      }
    '';
    mode = "0400";
  };

  networking.wireless = {
    enable = true;
    extraConfigFiles = [ config.sops.templates."wpa_supplicant-home.conf".path ];
  };

  # The wpa_supplicant launcher always passes `-c /etc/wpa_supplicant.conf`,
  # but the NixOS module only generates that file when `networks` is set
  # inline. With sops-only config (extraConfigFiles via `-I`), provide an
  # empty stub so wpa_supplicant doesn't abort before reading the include.
  environment.etc."wpa_supplicant.conf".text = "";

  homelab.network.enable = true;

  # Pi 5: nixos-hardware raspberry-pi-5 module enables
  # boot.loader.generic-extlinux-compatible; NVMe-first boot order is in the
  # Pi's EEPROM (already set on this unit).

  services.klipper = {
    enable = true;
    user = "klipper";
    group = "klipper";
    mutableConfig = false;
    configFile = ./printer.cfg;
    firmwares = { };
  };

  services.moonraker = {
    enable = true;
    user = "klipper";
    group = "klipper";
    allowSystemControl = true;
    address = "0.0.0.0";
    port = 7125;
    settings = {
      authorization = {
        cors_domains = [
          "http://*.home.arpa"
          "http://*.local"
          "http://*.lan"
        ];
        trusted_clients = [
          "10.0.0.0/8"
          "127.0.0.0/8"
          "169.254.0.0/16"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "FE80::/10"
          "::1/128"
          "2001:470:482f::/48"
        ];
      };
      octoprint_compat = { };
      history = { };
    };
  };

  services.mainsail = {
    enable = true;
    hostName = "skyforge.home.arpa";
  };

  networking.firewall.allowedTCPPorts = [ 80 7125 ];

  security.polkit.enable = true;

  users.users.klipper = {
    isSystemUser = true;
    group = "klipper";
    extraGroups = [ "dialout" "tty" ];
  };
  users.groups.klipper = { };

  system.stateVersion = "25.11";
}
