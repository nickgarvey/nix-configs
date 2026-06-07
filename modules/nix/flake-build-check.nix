{ config, lib, pkgs, ... }:

let
  cfg = config.services.flakeBuildCheck;
in
{
  options.services.flakeBuildCheck = {
    enable = lib.mkEnableOption "weekly fresh-checkout build of all flake outputs";

    flakeUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/nickgarvey/nix-configs.git";
      description = "Git URL to clone for the fresh-checkout build.";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 02:00:00";
      description = "systemd OnCalendar expression for the build timer.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.flake-build-check = {
      description = "Fresh-checkout build of all nix-configs flake outputs";
      path = with pkgs; [ git nix jq coreutils gnused ];
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        CacheDirectory = "flake-build-check";
        WorkingDirectory = "/var/cache/flake-build-check";
        Environment = [
          "HOME=/var/cache/flake-build-check"
          "XDG_CACHE_HOME=/var/cache/flake-build-check"
        ];
      };
      script = ''
        set -euo pipefail
        rm -rf repo
        git clone --depth 1 ${cfg.flakeUrl} repo
        cd repo

        nix flake update

        nix flake check --print-build-logs

        nix flake show --json --all-systems 2>/dev/null \
          | jq -r '.nixosConfigurations | keys[]' \
          | while read -r host; do
              echo "==> building nixosConfigurations.$host"
              nix build --no-link --print-build-logs \
                ".#nixosConfigurations.$host.config.system.build.toplevel"
            done
      '';
    };

    systemd.timers.flake-build-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = false;  # if host is down at the trigger, skip — don't catch up later
        RandomizedDelaySec = 0;
      };
    };
  };
}
