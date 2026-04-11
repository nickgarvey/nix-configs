{ config, lib, pkgs, ... }:

{
  # Persistent storage for Unifi data (MongoDB, config, backups)
  systemd.tmpfiles.rules = [
    "d /var/lib/unifi 0700 root root - -"
  ];

  # Raise TasksMax so the watchdog can still restart unifi when threads leak
  systemd.services."container@unifi".serviceConfig.TasksMax = 65536;

  containers.unifi = {
    autoStart = true;
    privateNetwork = false; # host networking — binds to router's interfaces

    bindMounts = {
      "/var/lib/unifi" = {
        hostPath = "/var/lib/unifi";
        isReadOnly = false;
      };
    };

    config = { config, pkgs, lib, ... }: {
      nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "unifi-controller"
        "mongodb"
      ];

      services.unifi = {
        enable = true;
        openFirewall = false; # router uses nftables directly
      };

      # Health-check: restart unifi if the web UI stops responding.
      # Catches the cron4j thread leak that exhausts TasksMax after ~19h.
      systemd.services.unifi-watchdog = {
        description = "Restart unifi if health check fails";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = let
            script = pkgs.writeShellScript "unifi-watchdog" ''
              if ! ${pkgs.curl}/bin/curl -skf --max-time 10 https://localhost:8443/manage >/dev/null 2>&1; then
                echo "Unifi health check failed, restarting..."
                systemctl restart unifi
              fi
            '';
          in "${script}";
        };
      };

      systemd.timers.unifi-watchdog = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "5min";    # first check 5min after boot
          OnUnitActiveSec = "2min"; # then every 2min
        };
      };

      system.stateVersion = "25.05";
    };
  };
}
