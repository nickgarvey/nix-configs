{ config, lib, pkgs, inputs, ... }:
let
  localStoragePath = "/var/lib/rancher/k3s/storage";
  xone-dongle-firmware = pkgs.callPackage ../../pkgs/xone-dongle-firmware { };
in
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/common-workstation.nix
    ../../modules/nixos-common.nix
    ../../modules/steam.nix
    ./hardware-configuration.nix
  ];

  # Enable Xbox wireless dongle support
  hardware.xone.enable = true;

  # Override firmware to include all dongle variants (02e6, 02fe, 02f9, 091e)
  hardware.firmware = lib.mkForce [ xone-dongle-firmware ];

  networking.hostName = "framework";

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
