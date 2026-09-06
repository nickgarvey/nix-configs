{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/desktop/common-workstation.nix
    ../../modules/desktop/niri.nix
    ../../modules/networking/network-manager.nix
    ../../modules/nix/nix-remote-builder-client.nix
    ../../modules/desktop/upower-overlay.nix
    ../../modules/desktop/rtl-sdr.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  networking.hostName = "dovahkiin";
  networking.networkmanager.wifi.powersave = false;

  # The MT7925 (RZ717) Wi-Fi 7 firmware mailbox hangs when the PCIe link
  # enters ASPM L1, causing "Message ... timeout" firmware resets and dropped
  # connections. Disable L1 ASPM for just this device.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x0717", ATTR{link/l1_aspm}="0"
  '';

  # Framework 13 internal panel (13.5" 2880x1920). Pin scale 2.0.
  # The LG TV defaults to its EDID-preferred 3840x2160@60; pin 120 explicitly,
  # which is the highest mode it offers. It reports no VRR support.
  homelab.niri.outputs = ''
    output "eDP-1" {
        scale 2.0
    }

    output "LG Electronics LG TV SSCR2 0x01010101" {
        mode "3840x2160@120.000"
        scale 1.0
    }
  '';

  homelab.niri.hasBattery = true;

  services.fwupd.enable = true;

  # The framework-amd-ai-300-series nixos-hardware profile enables fprintd by
  # default (lib.mkDefault), which adds pam_fprintd to the greetd login stack —
  # tuigreet then waits on a fingerprint swipe and blocks password entry. Disable
  # it: sudo is passwordless and there's no lock screen, so the reader is unused.
  services.fprintd.enable = false;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  users.users.ngarvey.packages = with pkgs; [
    signal-desktop
    vlc
    openmw
    # Rhythm game. ITGmania is the maintained StepMania 5.1 fork; Zmod Simply
    # Love is the community-standard theme, selected in Options -> Appearance.
    (itgmania.override {
      extraPackages = [ itgmaniaPackages.zmod-simply-love ];
    })
  ];

  systemd.user.tmpfiles.users.ngarvey.rules =
    let
      seed = pkgs.writeText "itgmania-preferences.ini" ''
        [Options]
        AdditionalSongFolders=/home/ngarvey/local-drive/stepmania
      '';
    in [
      "d %h/.itgmania/Save 0755 - - -"
      "C %h/.itgmania/Save/Preferences.ini 0644 - - - ${seed}"
    ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "yes";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  system.stateVersion = "25.11";
}
