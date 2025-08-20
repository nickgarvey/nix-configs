{ config, lib, pkgs, inputs, sops-nix, ... }:
  {
    environment.systemPackages = with pkgs; [
      pciutils
      atop
    ] ++ config.commonConfig.commonPackages;

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    sops.defaultSopsFile = ../secrets/k3s.yaml;
    sops.defaultSopsFormat = "yaml";
    sops.age.keyFile = "/root/.config/sops/age/keys.txt";
    sops.secrets.cluster_token = { };

    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    services.k3s = {
      enable = true;
      tokenFile = "/run/secrets/cluster_token";
      role = "server";
      extraFlags = [ "--write-kubeconfig-mode=644" ];
    };

    networking.firewall = {
      allowedTCPPorts = [ 6443 2379 2380 10250 ]; # K3s API server, etcd, etcd, metrics
      allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
    };

    services.qemuGuest.enable = true;

    # Longhorn settings
    # https://github.com/longhorn/longhorn/issues/2166#issuecomment-2994323945
    services.openiscsi = {
      enable = true;
      name = "${config.networking.hostName}-initiatorhost";
    };
    systemd.services.iscsid.serviceConfig = {
      PrivateMounts = "yes";
      BindPaths = "/run/current-system/sw/bin:/bin";
    };

    system.stateVersion = "25.11"; # Do not change!
}
