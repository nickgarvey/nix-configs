{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/networkd.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/nix/nix-binary-cache.nix
    ../../modules/nix/flake-build-check.nix
    ../../modules/llms/vllm-docker.nix
    ../../modules/containers/garage.nix
    inputs.sops-nix.nixosModules.sops
  ];

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.cudaSupport = true;

  time.timeZone = "America/Los_Angeles";

  services.icmpv6-archive.enable = true;

  homelab.network.enable = true;
  # Required so the garage container (on vmbr0) can route to its peer's
  # delegated /64 — crosses interfaces, needs IPv6 forwarding.
  homelab.network.ipv6Forward = true;

  # Bridge for the garage nspawn container to get LAN access (IPv6 auto-derived
  # from lan-hosts.nix). Mirrors lydia's setup.
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp14s0";
    ipv4 = {
      address = "10.28.8.80/16";
      gateway = "10.28.0.1";
    };
    # talos's own LAN identity is the static 2001:470:482f::5 (lan-hosts.nix).
    # suppressSlaac stops networkd adding a second, dynamic LAN-/64 address
    # on top of it.
    ipv6.suppressSlaac = true;
    # tarrasque (garage container) lives in the delegated 2001:470:482f:201::/64.
    # Carry that /64's gateway on vmbr0 so the container's hostBridgeAddress
    # next-hop resolves and the router's on-link route for the /64
    # (modules/router/lan-ipv6.nix) NDP-resolves to us.
    ipv6.extraAddresses = [ "2001:470:482f:201::1/64" ];
  };

  fileSystems."/fast/garage" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@garage" "nofail" ];
  };

  nspawn.garage = {
    hostBridge = "vmbr0";
    localAddress6 = "2001:470:482f:201::2/64";
    hostBridgeAddress = "2001:470:482f:201::1";
    dataPath = "/fast/garage";
    hostname = "tarrasque";
    capacity = "1T";
    replicationFactor = 2;
    peers = [ "1f19395c7b916da44c6acff1a831ddbf7fc294a020b071704f04b6d17a0277dc@garage-aboleth.home.arpa:3901" ];
  };

  # vLLM inference server (official docker image) serving Qwen3.6-27B NVFP4 on
  # the single RTX 5090 (32 GB). The model is synced from the garage llm-models
  # S3 bucket to local disk (loadFormat = "local"), which the MTP speculative
  # decode draft loader requires. NVFP4 weights (~20 GB, incl. quantized
  # linear-attn layers) run on the 5090's sm_120 FP4 tensor cores;
  # compressed-tensors nvfp4 is auto-detected. The v0.23.0 image is cu130 +
  # flashinfer + modelopt_fp4.
  homelab.vllmDocker = {
    enable = true;
    model = "Qwen3.6-27B-NVFP4";
    loadFormat = "local";
    extraArgs = [
      # Single request at a time: captures only batch-size-1 CUDA graphs,
      # keeping startup memory low.
      "--max-num-seqs" "1"
      # 240K context at gpu-memory-utilization 0.97. The BF16 MTP head
      # (~0.85 GiB) eats KV headroom, so the full 262K doesn't fit with
      # speculative decode on; 245760 is the practical max.
      "--max-model-len" "245760"
      "--gpu-memory-utilization" "0.97"
      "--kv-cache-dtype" "fp8_e4m3"
      "--reasoning-parser" "qwen3"
      "--enable-auto-tool-choice"
      "--tool-call-parser" "qwen3_xml"
      # MTP speculative decoding via the checkpoint's BF16 MTP head
      # (~80% draft acceptance, ~1.9x decode).
      "--speculative-config" ''{"method":"mtp","num_speculative_tokens":3}''
      # Log the effective sampling params of each request (INFO level logs
      # params only, not prompt or output). max-log-len 0 redacts the prompt
      # even if DEBUG logging is ever enabled.
      "--enable-log-requests"
      "--max-log-len" "0"
    ];
  };

  networking = {
    hostName = "talos";
    hostId = "a4c946db";
  };

  nix.settings = {
    download-buffer-size = 524288000;
    max-jobs = 2;
    cores = 0;
  };

  # Auto-reboot if the box wedges while unattended (last hang lasted 3 days).
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10min";
  };

  # Fence nix-daemon (and all build children) so a runaway build can't starve
  # ssh/system. CPUQuota leaves 1 physical core (2 SMT threads) free; MemoryMax
  # OOM-kills inside the build cgroup before the host wedges.
  systemd.services.nix-daemon.serviceConfig = {
    CPUQuota = "1500%";
    MemoryHigh = "40G";
    MemoryMax = "48G";
  };

  zramSwap.enable = true;

  services.flakeBuildCheck.enable = true;

  services.nixBinaryCache = {
    enable = true;
    signingKeySopsFile = ../../secrets/nix-builder.yaml;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvgPFo276pFe75SimIDp5JwKrIhSzD+ypRzt4GArzZ nix-builder"
    ];
  };

  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    enableOnBoot = true;
    # IPv6 on the default bridge so containers can reach the IPv6-only garage
    # S3 endpoint (the vLLM model store). ULA subnet + ip6tables gives NAT66:
    # container traffic is masqueraded to talos's LAN address, which already
    # routes to the garage container (IPv6 forwarding is on). Avoids needing
    # --network=host just to get IPv6.
    daemon.settings = {
      ipv6 = true;
      fixed-cidr-v6 = "fd00:d0cc::/64";
      ip6tables = true;
    };
  };

  # resolved handles split-DNS: Tailscale pushes its nameservers for ts.net
  # domains, while DHCP-provided DNS is used for everything else.
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "false";
  };
  networking.networkmanager.dns = "systemd-resolved";

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-dns"
      "--operator=ngarvey"
      "--exit-node-allow-lan-access"
    ];
  };

  boot = {
    binfmt.emulatedSystems = [ "aarch64-linux" ];

    kernelPackages = pkgs.linuxPackages_latest;

    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    kernelModules = [ "nvidia" "nvidia_drm" "nvidia_uvm" "nvidia_modeset" ];
    kernelParams = [
      "pcie_aspm=off"
    ];

    kernel.sysctl = {
      "kernel.panic" = 10;
    };

  };

  users.users.ngarvey = {
    uid = 1000;
    extraGroups = [ "docker" ];
    packages = with pkgs; [
      nvidia-container-toolkit
      rsync
    ];
  };

  hardware = {
    nvidia = {
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = false;
      open = true;
      nvidiaSettings = true;
      nvidiaPersistenced = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
    nvidia-container-toolkit.enable = true;
  };

  # Satisfies nvidia-container-toolkit's driver-presence assertion. xserver
  # itself is not enabled — this just declares which driver the toolkit can
  # find for Docker GPU passthrough.
  services.xserver.videoDrivers = [ "nvidia" ];

  system.stateVersion = "25.05";
}
