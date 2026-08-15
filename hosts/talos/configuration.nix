{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/networkd.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    inputs.sops-nix.nixosModules.sops
  ];

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.cudaSupport = true;

  time.timeZone = "America/Los_Angeles";

  services.icmpv6-archive.enable = true;

  homelab.network.enable = true;

  # Bridge over the LAN interface (IPv6 auto-derived from lan-hosts.nix).
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
  };

  # Retired garage node (tarrasque). Kept mounted while its data is still a
  # second copy of the cluster that now runs only on lydia.
  fileSystems."/fast/garage" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@garage" "nofail" ];
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
  # find for GPU passthrough.
  services.xserver.videoDrivers = [ "nvidia" ];

  system.stateVersion = "25.05";
}
