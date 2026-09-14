{ config, lib, pkgs, inputs, ... }:

let
  # xwayland-satellite 0.8.2 focuses X11 override-redirect popups, which makes
  # Steam's top-bar menus (and other dropdowns) close ~35ms after opening.
  # Upstream fixed it in PR #494 (commit add2795) but has not cut a release, so
  # build that commit until nixpkgs ships a version containing it.
  xwaylandSatelliteRev = "add2795134593faafce60e404a0a75df68e9ee0c";
  xwaylandSatelliteSrc = pkgs.fetchFromGitHub {
    owner = "Supreeeme";
    repo = "xwayland-satellite";
    rev = xwaylandSatelliteRev;
    hash = "sha256-0TxfMgqW0/BLD4M942c5DCKYrtPvzsPJwvdcco4LQUM=";
  };
  xwayland-satellite = pkgs.xwayland-satellite.overrideAttrs (old: {
    version = "0.8.2-unstable-2026-09-09";
    src = xwaylandSatelliteSrc;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit (old) pname;
      version = "0.8.2-unstable-2026-09-09";
      src = xwaylandSatelliteSrc;
      hash = "sha256-s1gl9eR6Mt2QLrhfcowstPFjzwE/lz4PJhJzWYHoIHg=";
    };
  });

  # The pin is temporary, so it expires rather than rots: the check trips on the
  # first rebuild whose flake or nixpkgs commit lands after the deadline.
  xwaylandSatelliteDeadline = 1796083200; # 2026-12-01T00:00:00Z
  flakeTime = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;
in
{
  options.homelab.niri.outputs = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = ''
      Host-specific niri `output "..." { ... }` block(s) in KDL syntax,
      appended to the shared configs/niri.kdl at build time. Lets each
      workstation pin its own monitor mode/scale without forking niri.kdl.
    '';
  };

  options.homelab.niri.hasBattery = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Whether this host has a battery. When true, the waybar status bar gains
      a battery module. Leave false on desktops so the bar shows no battery slot.
    '';
  };

  config = {
    assertions = [{
      assertion = flakeTime < xwaylandSatelliteDeadline;
      message = ''
        The xwayland-satellite pin in modules/desktop/niri.nix expired on
        2026-12-01. If nixpkgs' xwayland-satellite is newer than 0.8.2 (i.e.
        includes upstream commit ${xwaylandSatelliteRev}), delete the pin and
        use pkgs.xwayland-satellite again. Otherwise push the deadline out
        deliberately.
      '';
    }];

    # Niri, a scrollable-tiling Wayland compositor.
    programs.niri.enable = true;

    # Niri ecosystem tooling: status bar, launcher, and X11 compatibility.
    environment.systemPackages = with pkgs; [
      waybar              # status bar (spawned at niri startup)
      fuzzel              # application launcher (Mod+D)
      xwayland-satellite  # provides DISPLAY for X11 apps (e.g. Steam) under niri
      networkmanagerapplet # nm-applet (tray) + nm-connection-editor (GUI) for waybar
      pavucontrol         # PulseAudio volume/mixer GUI (opened from waybar audio module)
      brightnessctl       # backlight control (XF86MonBrightness keys in niri.kdl)
      gnome-themes-extra  # provides the Adwaita-dark GTK theme (dark mode)
    ];

    # Dark mode. Chromium-based apps (helium) and libadwaita/GTK4 read the
    # color-scheme preference via the XDG portal, which is backed by this dconf
    # key; gtk-theme + GTK_THEME cover older GTK3 apps.
    programs.dconf = {
      enable = true;
      profiles.user.databases = [{
        settings."org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "Adwaita-dark";
        };
      }];
    };
    environment.sessionVariables.GTK_THEME = "Adwaita:dark";

    # greetd + tuigreet: a minimal text login on the monitor that launches niri.
    # Replaces the default lightdm fallback (only one DM can own seat0).
    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd niri-session";
        user = "greeter";
      };
    };
  };
}
