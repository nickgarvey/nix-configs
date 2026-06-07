{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.opencloud-desktop ];

  systemd.tmpfiles.rules = [
    "d /home/ngarvey/opencloud 0755 ngarvey users -"
  ];

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
