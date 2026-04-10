{ config, lib, pkgs, inputs, sops-nix, ... }:
let
  cfg = config.k3sConfig;
  isServer = config.services.k3s.role == "server";
  isAgent = config.services.k3s.role == "agent";
  isFirstNode = cfg.isFirstNode;

  # Derive node IPv6 from lan-hosts.nix
  inherit (import ./lan-hosts.nix) lanHosts;
  hostname = config.networking.hostName;
  hostEntry = lib.findFirst (h: h.hostname == hostname) null lanHosts;
  nodeIpFlags = lib.optionals (hostEntry != null && hostEntry.ipv6 != null) [
    "--node-ip=${hostEntry.ipv6}"
  ];
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
    ];

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
        "zot.zot.k8s.home.arpa":
          endpoint:
            - "http://zot.zot.k8s.home.arpa:5000"
    '';

    systemd.services.k3s.restartTriggers = [
      config.environment.etc."rancher/k3s/registries.yaml".source
    ];

    services.k3s = {
      enable = true;
      tokenFile = "/run/secrets/cluster_token";
      role = lib.mkDefault "server";
      clusterInit = lib.mkIf isFirstNode true;
      serverAddr = lib.mkIf (!isFirstNode) "https://k3s-api.home.arpa:6443";
      extraFlags = lib.optionals isServer [
        "--write-kubeconfig-mode=644"
        "--disable=servicelb"
        "--disable=traefik"
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable-kube-proxy"
        "--cluster-cidr=fd42::/48"
        "--service-cidr=fd43::/112"
        "--tls-san=k3s-api.home.arpa"
      ] ++ lib.optionals (isServer && hostEntry != null && hostEntry.ipv6 != null) [
        "--etcd-arg=--advertise-peer-urls=https://[${hostEntry.ipv6}]:2380"
      ] ++ nodeIpFlags;
    };

    homelab.network.ipv4Forward = true;
    homelab.network.ipv6Forward = true;

    # Disable IPv6 RA/SLAAC — etcd peers must use the static address only
    systemd.network.networks."25-static".ipv6AcceptRAConfig.UseAutonomousPrefix = false;
    systemd.network.networks."25-static".networkConfig.IPv6AcceptRA = false;

    networking.firewall = {
      allowedTCPPorts = [ 10250 4240 4244 4245 ]  # Kubelet, Cilium health, Hubble
        ++ lib.optionals isServer [ 6443 2379 2380 ];
      allowedUDPPorts = [ 8472 ];  # VXLAN (Cilium tunnel mode fallback)
    };

    # Longhorn settings
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
