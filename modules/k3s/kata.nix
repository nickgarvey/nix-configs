# Kata Containers: opt-in VM-isolated pod sandboxes via a `kata` RuntimeClass.
{ config, lib, pkgs, ... }:
let
  isServer = config.services.k3s.role == "server";

  kataConfigToml = "${pkgs.kata-runtime}/share/defaults/kata-containers/configuration.toml";

  # k3s merges this template into its generated containerd config; the "base"
  # template is provided by k3s itself. containerd 2.x (bundled with k3s
  # 1.35+) registers CRI runtimes under io.containerd.cri.v1.runtime.
  containerdConfigTemplate = pkgs.writeText "k3s-containerd-config.toml.tmpl" ''
    {{ template "base" . }}

    [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata]
      runtime_type = "io.containerd.kata.v2"
      privileged_without_host_devices = true
      pod_annotations = ["io.katacontainers.*"]
      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata.options]
        ConfigPath = "/etc/kata-containers/configuration.toml"
  '';

  kataRuntimeClass = pkgs.writeText "kata-runtimeclass.yaml" ''
    apiVersion: node.k8s.io/v1
    kind: RuntimeClass
    metadata:
      name: kata
    handler: kata
  '';
in
{
  environment.systemPackages = [
    pkgs.kata-runtime
  ];

  environment.etc."kata-containers/configuration.toml".source = kataConfigToml;

  # k3s's systemd unit runs with a minimal PATH (coreutils/findutils/grep/sed
  # only), so containerd can't resolve containerd-shim-kata-v2 without this.
  systemd.services.k3s.path = [ pkgs.kata-runtime ];

  systemd.tmpfiles.rules = [
    "L+ /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl - - - - ${containerdConfigTemplate}"
  ] ++ lib.optionals isServer [
    "L+ /var/lib/rancher/k3s/server/manifests/kata-runtimeclass.yaml - - - - ${kataRuntimeClass}"
  ];

  systemd.services.k3s.restartTriggers = [
    config.environment.etc."kata-containers/configuration.toml".source
    containerdConfigTemplate
    kataRuntimeClass
  ];
}
