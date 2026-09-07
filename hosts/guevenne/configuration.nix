{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/desktop/common-tv.nix
    ../../modules/networking/network-manager.nix
  ];

  networking.hostName = "guevenne";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The TV's preferred mode is 3840x2160, but the Radeon 880M iGPU should not
  # try to render games at 4K: gamescope draws at 1080p and FSR-upscales to the
  # panel. --prefer-output pins the session to the TV, keeping it off the
  # laptop's broken internal panel should eDP-1 ever report connected.
  programs.steam.gamescopeSession = {
    args = [
      "--prefer-output" "HDMI-A-1"
      "-W" "3840" "-H" "2160"
      "-w" "1920" "-h" "1080"
      "-r" "60"
      "-F" "fsr"
      # Two Xwayland servers: Steam sits on the first, and puts every game or
      # non-Steam shortcut it launches on the second. gamescope presents
      # whatever is on that second server, which is how a launched app reaches
      # the screen at all. With a single server the app's window just sits
      # behind Big Picture, running but never shown.
      "--xwayland-count" "2"
      # Non-Steam shortcuts (Jellyfin, YouTube) open a window sized by the app
      # rather than the display, which gamescope would then pillarbox. Force
      # every window inside the session to the full nested display instead.
      "--force-windows-fullscreen"
    ];
    env.STEAM_MULTIPLE_XWAYLANDS = "1";
  };

  system.stateVersion = "25.11";
}
