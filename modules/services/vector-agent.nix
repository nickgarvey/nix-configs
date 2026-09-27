{ config, lib, pkgs, ... }:

# Lightweight host metrics agent, pushed to Prometheus rather than scraped.
#
# Any nix file (imported anywhere) can contribute metrics by adding entries
# under homelab.metrics.sources / homelab.metrics.transforms — attrsOf options
# merge by key across every module that sets them, so metric definitions can
# live next to whatever they describe (see modules/microvm/smb.nix,
# hosts/lydia/configuration.nix) instead of all being crammed in here.
#
# A transform is wired to the remote_write sink automatically once it's a
# `log_to_metric` transform (i.e. it actually emits a metric event, as
# opposed to an intermediate `remap` transform that only reshapes fields).
{
  options.homelab.metrics = {
    sources = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Vector source definitions, merged into services.vector.settings.sources.";
    };
    transforms = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Vector transform definitions, merged into services.vector.settings.transforms.";
    };
  };

  config = {
    services.vector = {
      enable = true;
      settings = {
        sources = config.homelab.metrics.sources;
        transforms = config.homelab.metrics.transforms;
        sinks.prometheus_remote_write = {
          type = "prometheus_remote_write";
          inputs = [ "disk_usage" ] ++ builtins.attrNames (
            lib.filterAttrs (_: t: t.type == "log_to_metric") config.homelab.metrics.transforms
          );
          endpoint = "http://prometheus.prometheus.k8s.home.garvey.sh:9090/api/v1/write";
        };
      };
    };

    # Disk usage for every block-device-backed mount, as
    # host_filesystem_used_ratio{hostname,device,mountpoint,filesystem}. The
    # /dev/* match keeps out tmpfs, overlays, network filesystems and virtual
    # mounts; kubelet volume mounts are left out because Prometheus already gets
    # those from kubelet_volume_stats_*. btrfs subvolumes of one filesystem show
    # up once per mountpoint with the same ratio; the alert rule dedupes by device.
    homelab.metrics.sources.disk = {
      type = "host_metrics";
      collectors = [ "filesystem" ];
      scrape_interval_secs = 60;
      filesystem = {
        devices.includes = [ "/dev/*" ];
        mountpoints.excludes = [ "/var/lib/kubelet/*" ];
      };
    };

    # The metric events feed the sink directly (there is no log_to_metric step),
    # so this remap is wired to it by name above. It keeps only the ratio and
    # renames the `host` tag to the `hostname` label the other metrics use.
    homelab.metrics.transforms.disk_usage = {
      type = "remap";
      inputs = [ "disk" ];
      drop_on_abort = true;
      source = ''
        if .name != "filesystem_used_ratio" { abort }
        .tags.hostname = del(.tags.host)
        del(.tags.collector)
      '';
    };

    homelab.metrics.sources.kernel_version = {
      type = "exec";
      mode = "scheduled";
      scheduled.exec_interval_secs = 300;
      command = [ "uname" "-r" ];
    };

    homelab.metrics.transforms.kernel_fields = {
      type = "remap";
      inputs = [ "kernel_version" ];
      source = ''
        .release = strip_whitespace!(to_string!(.message))
        .value = 1
      '';
    };

    homelab.metrics.transforms.kernel_metric = {
      type = "log_to_metric";
      inputs = [ "kernel_fields" ];
      metrics = [{
        type = "gauge";
        field = "value";
        name = "node_uname_info";
        tags = {
          release = "{{ release }}";
          hostname = config.networking.hostName;
        };
      }];
    };
  };
}
