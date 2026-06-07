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
    ];

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
