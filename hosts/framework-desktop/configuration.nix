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
    ./hardware-configuration.nix
  ];

  services.icmpv6-archive.enable = true;

  # Enable Xbox wireless dongle support
  hardware.xone.enable = true;

  # Add Xbox dongle firmware (append to existing firmware, don't replace)
  hardware.firmware = [ xone-dongle-firmware ];

  homelab.network.enable = true;

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
