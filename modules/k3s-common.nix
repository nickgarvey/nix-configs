{ config, lib, pkgs, inputs, sops-nix, ... }:
let
  cfg = config.k3sConfig;
  isServer = config.services.k3s.role == "server";
  isAgent = config.services.k3s.role == "agent";
  isFirstNode = cfg.isFirstNode;
in
{
  options.k3sConfig = {
    isFirstNode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this is the first/initial node that bootstraps the cluster";
    };
  };

  config = {
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

    # KUBECONFIG only exists on server nodes
    environment.variables = lib.mkIf isServer {
      KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    };

    # Configure Zot registry (HTTP) for k3s
    environment.etc."rancher/k3s/registries.yaml".text = ''
      mirrors:
        "10.28.15.206:5000":
          endpoint:
            - "http://10.28.15.206:5000"
        "zot.home.arpa:5000":
          endpoint:
            - "http://zot.home.arpa:5000"
    '';

    systemd.services.k3s.restartTriggers = [
      config.environment.etc."rancher/k3s/registries.yaml".source
    ];

    services.k3s = {
      enable = true;
      tokenFile = "/run/secrets/cluster_token";
      role = lib.mkDefault "server";
      # First node bootstraps the cluster, others join it
      clusterInit = lib.mkIf isFirstNode true;
      serverAddr = lib.mkIf (!isFirstNode) "https://k3s-node-1.home.arpa:6443";
      # Server-specific flags
      extraFlags = lib.mkIf isServer [
        "--write-kubeconfig-mode=644"
        "--disable=servicelb"  # Using MetalLB instead
      ];
    };

    networking.firewall = {
      # Server ports: API server, etcd, etcd peers
      allowedTCPPorts = [ 10250 ] # Kubelet metrics (all nodes)
        ++ lib.optionals isServer [ 6443 2379 2380 ];
      allowedUDPPorts = [ 8472 ]; # Flannel VXLAN (all nodes)
    };

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
  };
}
