{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.services.temporalNixBuilder;
in
{
  options.services.temporalNixBuilder = {
    enable = lib.mkEnableOption "Temporal worker that builds all flake outputs nightly";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.temporal-workflows.packages.${pkgs.stdenv.hostPlatform.system}.nix-build-worker;
      defaultText = lib.literalExpression "inputs.temporal-workflows.packages.\${system}.nix-build-worker";
      description = "The nix-build-worker package to run.";
    };

    flakeUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/nickgarvey/nix-configs.git";
      description = ''
        Flake to clone and build. Passed to `git clone`, so it is a git URL or a
        path — not a nix flake reference.
      '';
    };

    temporalAddress = lib.mkOption {
      type = lib.types.str;
      default = "temporal.temporal.k8s.home.garvey.sh:7233";
      description = "host:port of the Temporal frontend's gRPC endpoint.";
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Temporal namespace.";
    };

    taskQueue = lib.mkOption {
      type = lib.types.str;
      default = "nix-build";
      description = "Task queue the worker polls.";
    };

    scheduleId = lib.mkOption {
      type = lib.types.str;
      default = "nix-configs-daily-build";
      description = ''
        Schedule the worker reconciles on startup. This module owns the
        schedule's shape, so edits made in the Temporal UI are overwritten on the
        next restart — except a pause, which is preserved.
      '';
    };

    cron = lib.mkOption {
      type = lib.types.str;
      default = "0 2 * * *";
      description = "Cron expression for the daily build.";
    };

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone;
      defaultText = lib.literalExpression "config.time.timeZone";
      description = "Timezone the cron expression is interpreted in.";
    };

    maxConcurrentBuilds = lib.mkOption {
      type = lib.types.ints.positive;
      default = config.nix.settings.max-jobs or 2;
      defaultText = lib.literalExpression "config.nix.settings.max-jobs";
      description = ''
        How many targets build at once. The workflow starts every target
        together and the worker decides how many actually run, so this is the
        concurrency limit for the whole job.
      '';
    };

    requireHost = lib.mkOption {
      type = lib.types.str;
      default = "talos";
      description = ''
        The worker refuses to start unless the machine's hostname matches. The
        job exists to prime this host's store, which serves the fleet as a
        binary cache — building anywhere else primes the wrong store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.networking.hostName == cfg.requireHost;
      message = ''
        services.temporalNixBuilder is enabled on '${config.networking.hostName}'
        but requireHost is '${cfg.requireHost}'. The worker would refuse to start.
      '';
    }];

    systemd.services.temporal-nix-builder = {
      description = "Temporal worker building all nix-configs flake outputs";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "nix-daemon.service" ];
      wants = [ "network-online.target" ];

      path = with pkgs; [ git nix ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${cfg.package}/bin/nix-build-worker"
          "-address ${cfg.temporalAddress}"
          "-namespace ${cfg.namespace}"
          "-task-queue ${cfg.taskQueue}"
          "-schedule-id ${cfg.scheduleId}"
          "-flake-url ${cfg.flakeUrl}"
          "-state-dir /var/lib/temporal-nix-builder"
          "-cron '${cfg.cron}'"
          "-timezone ${cfg.timeZone}"
          "-system ${pkgs.stdenv.hostPlatform.system}"
          "-max-concurrent ${toString cfg.maxConcurrentBuilds}"
          "-require-host ${cfg.requireHost}"
        ];
        Restart = "always";
        # The frontend lives in the k3s cluster; when that is down, retry slowly
        # rather than hammering it.
        RestartSec = 30;

        DynamicUser = true;
        # Checkouts and the gcroots that keep each run's results alive both live
        # here, so this must survive reboots — CacheDirectory would not.
        StateDirectory = "temporal-nix-builder";
        WorkingDirectory = "/var/lib/temporal-nix-builder";
        Environment = [
          "HOME=/var/lib/temporal-nix-builder"
          "XDG_CACHE_HOME=/var/lib/temporal-nix-builder/.cache"
        ];
      };
    };
  };
}
