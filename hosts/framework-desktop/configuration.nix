{ config, lib, pkgs, inputs, ... }:
let
  xone-dongle-firmware = pkgs.callPackage ../../pkgs/xone-dongle-firmware { };
in
{
  imports = [
    ../../modules/common-workstation.nix
    ../../modules/nixos-common.nix
    ../../modules/lan-network.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/steam.nix
    ../../modules/containers/llama-cpp.nix
    ../../modules/nix-remote-builder-client.nix
    ./hardware-configuration.nix
  ];

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "tarrasque";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZcTP3OJYZenl8bb9fC9NTIvFCOaxs2gi1Mz4OhAByw";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
  };

  services.icmpv6-archive.enable = true;

  # Enable Xbox wireless dongle support
  hardware.xone.enable = true;

  # Add Xbox dongle firmware (append to existing firmware, don't replace)
  hardware.firmware = [ xone-dongle-firmware ];

  homelab.network.enable = true;

  homelab.llama-cpp = {
    enable = true;
    backend = "vulkan";
    models = [
      { name = "qwen3.5-27b"; repo = "unsloth/Qwen3.5-27B-GGUF"; filter = "UD-Q4_K_XL"; }
      { name = "qwen3.5-9b";  repo = "unsloth/Qwen3.5-9B-GGUF";  filter = "UD-Q4_K_XL"; }
      { name = "qwen3.5-4b";  repo = "unsloth/Qwen3.5-4B-GGUF";  filter = "UD-Q4_K_XL"; }
    ];
  };

  networking.hostName = "framework-desktop";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # AMD Strix Halo iGPU configuration for large LLM models
  # https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes/
  boot.kernelParams = [
    "amd_iommu=off"
    "amdgpu.gttsize=126976"
    "ttm.pages_limit=32505856"
  ];

  # Enable autologin
  services.displayManager.autoLogin = {
    enable = true;
    user = "ngarvey";
  };

  system.stateVersion = "25.11";
}
