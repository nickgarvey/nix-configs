{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos-common.nix
    ../../modules/smb-automount.nix
    ../../modules/lan-network.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/nix-binary-cache.nix
    ../../modules/whisper-gpu.nix
    ../../modules/containers/llama-cpp.nix
    ../../modules/containers/garage.nix
    ../../modules/mlx-direct-peer.nix
    inputs.sops-nix.nixosModules.sops
  ];

  services.mlxDirectPeer.enable = true;

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.cudaSupport = true;

  time.timeZone = "America/Los_Angeles";

  services.icmpv6-archive.enable = true;

  homelab.network.enable = true;

  # Bridge for the garage nspawn container to get LAN access (IPv6 auto-derived
  # from lan-hosts.nix). Mirrors aboleth's setup.
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp14s0";
    ipv4 = {
      address = "10.28.8.80/16";
      gateway = "10.28.0.1";
    };
    # Tarrasque's IPv6 lives in 2001:470:482f:201::/64 (delegated), not the
    # LAN /64 — suppress SLAAC so it doesn't autoconfig a LAN-/64 address.
    ipv6.suppressSlaac = true;
  };
  # --- Storage: btrfs ---
  fileSystems."/fast/garage" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@garage" "nofail" ];
  };

  # --- Garage S3 (nspawn container, IPv6-only) ---
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

  homelab.llama-cpp = {
    enable = true;
    backend = "cuda";
    # Default to instruct/non-thinking mode for lower latency; clients pass
    # chat_template_kwargs.enable_thinking=true to opt back in.
    # Sampling matches Qwen3.6 instruct-mode recommendation (HF/Unsloth).
    extraArgs = [
      ''--chat-template-kwargs '{"enable_thinking":false}' ''
      "--temp 0.7"
      "--top-p 0.8"
      "--top-k 20"
      "--min-p 0.0"
      "--presence-penalty 1.5"
    ];
    models = [
      { name = "qwen3.6-27b"; repo = "unsloth/Qwen3.6-27B-GGUF"; filter = "UD-Q4_K_XL"; }
    ];
  };

  networking = {
    hostName = "tarrasque";
    hostId = "a4c946db";
  };

  nix.settings = {
    download-buffer-size = 524288000;
    max-jobs = 4;
    cores = 0;
  };

  # Auto-reboot if the box wedges while unattended (last hang lasted 3 days).
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10min";
  };

  zramSwap.enable = true;

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
      "net.ipv6.conf.all.forwarding" = 1;
      "kernel.panic" = 10;
    };

  };

  users.users.ngarvey = {
    uid = 1000;
    extraGroups = [ "docker" ];
    packages = with pkgs; [
      inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
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

  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Do not change!
}
