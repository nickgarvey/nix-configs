{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.opencloud-desktop ];

  systemd.tmpfiles.rules = [
    "d /home/ngarvey/opencloud 0755 ngarvey users -"
  ];

  # The client's "Launch on startup" writes ~/.config/autostart/OpenCloud.desktop with
  # Exec pointing at the inner .opencloud-wrapped binary (Qt resolves its own exe to the
  # unwrapped one under Nix). Launched that way NIXPKGS_QT6_QML_IMPORT_PATH is unset and
  # QtQuick.Controls/QtQuick.Layouts fail to load -> fatal QML popup. niri's xdg-autostart
  # generates app-OpenCloud@autostart.service from that file; mask it so only the wrapped
  # systemd service below launches opencloud. Immune to the client rewriting the file.
  systemd.user.services."app-OpenCloud@autostart".enable = false;

  systemd.user.services.opencloud-desktop = {
    description = "OpenCloud Desktop sync client";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.opencloud-desktop}/bin/opencloud";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
