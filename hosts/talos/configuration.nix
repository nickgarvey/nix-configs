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
    ../../modules/flake-build-check.nix
    ../../modules/whisper-gpu.nix
    ../../modules/containers/llama-cpp.nix
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
    # Tarrasque's IPv6 lives in 2001:470:482f:201::/64 (delegated), not the
    # LAN /64 — suppress SLAAC so it doesn't autoconfig a LAN-/64 address.
    ipv6.suppressSlaac = true;
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

  homelab.llama-cpp = {
    enable = true;
    backend = "cuda";
    # Thinking on by default; MoE active-3B keeps it fast enough.
    # Sampling matches Qwen3 thinking-mode recommendation (HF/Unsloth).
    extraArgs = [
      "--reasoning on"
      "--temp 0.6"
      "--top-p 0.95"
      "--top-k 20"
      "--min-p 0.0"
    ];
    models = [
      { name = "qwen3.6-35b-a3b"; repo = "unsloth/Qwen3.6-35B-A3B-GGUF"; filter = "UD-Q4_K_XL"; }
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

  system.stateVersion = "25.05";
}
