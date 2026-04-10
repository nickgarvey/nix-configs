{ config, lib, pkgs, ... }:

{
  # Persistent storage for Unifi data (MongoDB, config, backups)
  systemd.tmpfiles.rules = [
    "d /var/lib/unifi 0700 root root - -"
  ];

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

      system.stateVersion = "25.05";
    };
  };
}
