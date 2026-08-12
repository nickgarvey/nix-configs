{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.incus;
in
{
  options.homelab.incus = {
    enable = lib.mkEnableOption "Incus virtualisation host";

    storageSource = lib.mkOption {
      type = lib.types.str;
      description = "Host path backing the btrfs \"default\" storage pool.";
      example = "/fast/incus";
    };

    httpsAddress = lib.mkOption {
      type = lib.types.str;
      default = ":8443";
      description = "Listen address for the HTTPS API and web UI.";
    };

    adminUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users to add to the incus-admin group.";
    };

    metrics = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Export a per-VM uptime gauge through the homelab metrics pipeline.";
      };

      hostname = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "Value for the hostname tag on exported metrics.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;
      ui.enable = true;
      preseed = {
        config = {
          "core.https_address" = cfg.httpsAddress;
        };
        storage_pools = [
          {
            name = "default";
            driver = "btrfs";
            config = {
              source = cfg.storageSource;
            };
          }
        ];
      };
    };

    users.groups.incus-admin.members = cfg.adminUsers;

    # Running QEMU once faults it into the page cache, so incusd's startup
    # feature probe doesn't pay for the cold read. qemu_kvm is the same
    # derivation the incus module puts on incusd's PATH.
    #
    # "-" and the timeout keep this strictly best-effort: a slow or failed
    # warm-up must not stop incus from starting.
    systemd.services.incus.serviceConfig.ExecStartPre = lib.mkBefore [
      "-${pkgs.coreutils}/bin/timeout 60 ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 -version"
    ];

    # Incus VMs are created/destroyed dynamically, so their uptime can't be
    # hardcoded per-VM the way a static guest's can — enumerate whatever's
    # actually running at collection time instead.
    homelab.metrics.sources = lib.mkIf cfg.metrics.enable {
      incus_vm_uptime = {
        type = "exec";
        mode = "scheduled";
        scheduled.exec_interval_secs = 60;
        decoding.codec = "json";
        command = [
          "${pkgs.bash}/bin/bash"
          "-c"
          # Wrapped in an array (not one object per line) so a zero-VM result is
          # still valid JSON (`[]`) instead of empty stdout, which the decoder
          # below can't parse. Vector's json codec expands a top-level array into
          # one event per element.
          # started_at has fractional-second precision (like incus's created_at),
          # which jq's fromdateiso8601 can't parse — strip it before converting.
          # HOME must point somewhere writable: the incus CLI needs to create
          # ~/.config/incus for its client cert on first run, but vector's
          # systemd DynamicUser has no home directory by default.
          ''HOME=/var/lib/vector ${pkgs.incus}/bin/incus list --format json | ${pkgs.jq}/bin/jq -c '[.[] | select(.type=="virtual-machine" and .status=="Running") | {name: .name, uptime: ((now|floor) - (.state.started_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601))}]' ''
        ];
      };
    };

    homelab.metrics.transforms = lib.mkIf cfg.metrics.enable {
      incus_vm_uptime_metric = {
        type = "log_to_metric";
        inputs = [ "incus_vm_uptime" ];
        metrics = [{
          type = "gauge";
          field = "uptime";
          name = "incus_vm_uptime_seconds";
          tags = {
            vm = "{{ name }}";
            hostname = cfg.metrics.hostname;
          };
        }];
      };
    };

    # Vector needs Incus API access to enumerate VMs for incus_vm_uptime above.
    systemd.services.vector.serviceConfig.SupplementaryGroups =
      lib.mkIf cfg.metrics.enable [ "incus-admin" ];
  };
}
