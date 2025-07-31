{ config, lib, pkgs, inputs, sops-nix, ... }:
  {
    environment.systemPackages = with pkgs; [
      pciutils
      atop
    ] ++ config.commonConfig.commonPackages;

    boot.loader.grub.enable = true;

    sops.defaultSopsFile = ../secrets/k3s.yaml;
    sops.defaultSopsFormat = "yaml";
    sops.age.keyFile = "/root/.config/sops/age/keys.txt";
    sops.secrets.cluster_token = { };

    services.k3s = {
      enable = true;
      tokenFile = "/run/secrets/cluster_token";
      role = "server";
    };

    networking.firewall = {
      allowedTCPPorts = [ 6443 2379 2380 10250 ]; # K3s API server, etcd, etcd, metrics
      allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
    };

    services.qemuGuest.enable = true;

    system.stateVersion = "25.11"; # Do not change!
}
