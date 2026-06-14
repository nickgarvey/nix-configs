{ config, lib, pkgs, inputs, ... }:
let
  xone-dongle-firmware = pkgs.callPackage ../../pkgs/xone-dongle-firmware { };
in
{
  imports = [
    ../../modules/desktop/common-workstation.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/network-manager.nix
    ../../modules/icmpv6-archive
    ../../modules/icmpv6-archive/sops.nix
    ../../modules/desktop/steam.nix
    ../../modules/desktop/niri.nix
    ../../modules/desktop/opencloud-desktop.nix
    ../../modules/nix/nix-remote-builder-client.nix
    ./hardware-configuration.nix
  ];

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "talos";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZcTP3OJYZenl8bb9fC9NTIvFCOaxs2gi1Mz4OhAByw";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
  };

  services.icmpv6-archive.enable = true;

  # Enable Xbox wireless dongle support
  hardware.xone.enable = true;

  # Add Xbox dongle firmware (append to existing firmware, don't replace)
  hardware.firmware = [ xone-dongle-firmware ];

  # ASUS XG27UQDMS (4K 240Hz OLED), direct-connected on DP-2. niri otherwise
  # auto-picks the 60Hz "preferred" mode, so pin the full rate. VRR is on-demand:
  # it only engages for windows opted in via a window-rule (see the mpv rule in
  # configs/niri.kdl), which avoids OLED gamma flicker on the desktop.
  homelab.niri.outputs = ''
    output "DP-2" {
        mode "3840x2160@240.000"
        scale 1.5
        transform "normal"
        variable-refresh-rate on-demand=true
        position x=0 y=0
    }
  '';

  networking.hostName = "wabbajack";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # AMD Strix Halo iGPU configuration for large LLM models
  # https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes/
  boot.kernelParams = [
    "amd_iommu=off"
    "amdgpu.gttsize=126976"
    "ttm.pages_limit=32505856"
  ];

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  users.users.ngarvey.packages = with pkgs; [
    openmw
  ];

  system.stateVersion = "25.11";
}
