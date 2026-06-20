{ config, lib, pkgs, ... }:

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
    # Niri, a scrollable-tiling Wayland compositor.
    programs.niri.enable = true;

    # Niri ecosystem tooling: status bar, launcher, and X11 compatibility.
    environment.systemPackages = with pkgs; [
      waybar              # status bar (spawned at niri startup)
      fuzzel              # application launcher (Mod+D)
      xwayland-satellite  # provides DISPLAY for X11 apps (e.g. Steam) under niri
      networkmanagerapplet # nm-applet (tray) + nm-connection-editor (GUI) for waybar
      pwvucontrol         # PipeWire volume/mixer GUI (opened from waybar audio module)
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
