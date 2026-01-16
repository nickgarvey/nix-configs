{ config, lib, pkgs, inputs, ... }:
let
  localStoragePath = "/var/lib/rancher/k3s/storage";
in
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/common-workstation.nix
    ../../modules/nixos-common.nix
    ../../modules/steam.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "framework";

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # AMD Strix Halo iGPU configuration for large LLM models
  # https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes/
  boot.kernelParams = [
    "amd_iommu=off"
    "amdgpu.gttsize=126976"
    "ttm.pages_limit=32505856"
  ];
  services.k3s.role = "agent";

  # Enable autologin
  services.displayManager.autoLogin = {
    enable = true;
    user = "ngarvey";
  };

  assertions = [{
    assertion = config.fileSystems ? "${localStoragePath}";
    message = "Local storage partition must be mounted at ${localStoragePath}";
  }];
}
