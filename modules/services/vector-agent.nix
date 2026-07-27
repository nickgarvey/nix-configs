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
          inputs = builtins.attrNames (
            lib.filterAttrs (_: t: t.type == "log_to_metric") config.homelab.metrics.transforms
          );
          endpoint = "http://prometheus.prometheus.k8s.home.arpa:9090/api/v1/write";
        };
      };
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
