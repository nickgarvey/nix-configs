{ config, lib, pkgs, inputs, ... }:
# Framework Desktop (AMD Ryzen AI MAX+ 395) running headless as a server.
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/core/server-base.nix
    ../../modules/containers/garage.nix
  ];

  networking.hostName = "wabbajack";
  # Required so the garage container (on vmbr0) can route to its peer's
  # delegated /64 — crosses interfaces, needs IPv6 forwarding.
  homelab.network.ipv6Forward = true;

  # Bridge for the garage nspawn container to get LAN access (IPv6 auto-derived
  # from lan-hosts.nix). Mirrors lydia's setup.
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp191s0";
    ipv4 = {
      address = "10.28.1.10/16";
      gateway = "10.28.0.1";
    };
    # wabbajack's own LAN identity is the static 2001:470:482f::10
    # (lan-hosts.nix). suppressSlaac stops networkd adding a second, dynamic
    # LAN-/64 address on top of it.
    ipv6.suppressSlaac = true;
    # The garage container lives in the delegated 2001:470:482f:202::/64.
    # Carry that /64's gateway on vmbr0 so the container's hostBridgeAddress
    # next-hop resolves and the router's on-link route for the /64
    # (modules/router/lan-ipv6.nix) NDP-resolves to us.
    ipv6.extraAddresses = [ "2001:470:482f:202::1/64" ];
  };

  fileSystems."/fast/garage" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@garage" "nofail" ];
  };

  # --- Garage S3 (nspawn container, IPv6-only) ---
  # Second node of the two-node RF=2 cluster; lydia runs the other (aboleth).
  nspawn.garage = {
    hostBridge = "vmbr0";
    localAddress6 = "2001:470:482f:202::2/64";
    hostBridgeAddress = "2001:470:482f:202::1";
    dataPath = "/fast/garage";
    hostname = "wabbajack";
    capacity = "1.5T";
    replicationFactor = 2;
    tls.enable = true;
    peers = [ "1f19395c7b916da44c6acff1a831ddbf7fc294a020b071704f04b6d17a0277dc@[2001:470:482f:200::2]:3901" ];
  };

  # --- llama.cpp (Vulkan on the iGPU) ---
  # The amdgpu GTT limit defaults to about half of RAM (~62 GB), too small for
  # the ~90 GB weights plus KV cache. Raise it to ~124 GiB.
  boot.kernelParams = [
    "amdgpu.gttsize=126976"
    "ttm.pages_limit=32505856"
    "ttm.page_pool_size=32505856"
  ];

  # Qwen3.8-Flash-Next (125B MoE, 6B active). llama-server pulls the split GGUF
  # from HuggingFace into /var/cache/llama-cpp on first start.
  services.llama-cpp = {
    enable = true;
    package = pkgs.llama-cpp-vulkan;
    openFirewall = true;
    settings = {
      host = "::";
      port = 8080;
      hf-repo = "unsloth/Qwen3.8-Flash-Next-GGUF:UD-Q3_K_XL";
      alias = "qwen3.8-flash-next";
      ctx-size = 262144;
      n-gpu-layers = 999;
      flash-attn = "on";
      # Unified memory: with mmap the weights would sit in both page cache and GTT.
      load-mode = "none";
      parallel = 1;
      jinja = true;
      metrics = true;
      # Qwen's recommended thinking-mode sampling (model card).
      temp = 1.0;
      top-p = 0.95;
      top-k = 20;
      min-p = 0.0;
    };
  };
  systemd.services.llama-cpp = {
    # The first start downloads the model.
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # Mesa writes its shader cache under $XDG_CACHE_HOME; $HOME is unwritable.
    environment.XDG_CACHE_HOME = "/var/cache/llama-cpp";
    # DynamicUser needs the render group to open /dev/dri/renderD128.
    serviceConfig.SupplementaryGroups = [ "render" "video" ];
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Pinned so /home ownership stays stable across reinstalls.
  users.users.ngarvey.uid = 1000;

  system.stateVersion = "25.11";
}
