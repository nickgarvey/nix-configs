{ config, lib, pkgs, inputs, ... }:
let
  xone-dongle-firmware = pkgs.callPackage ../../pkgs/xone-dongle-firmware { };

  # Temporary diagnostics for slow `vector.service` shutdown on wabbajack.
  # VECTOR_LOG=warn,vector=debug surfaces per-sink/source shutdown flush
  # activity in journalctl -u vector (only vector's own crate at debug,
  # deps stay at warn to avoid flooding the journal), to find what's
  # blocking graceful stop (leading suspect: prometheus_remote_write sink
  # flush). Remove once root-caused, or push deadline out. Expires 2026-09-08.
  vectorDebugDeadline = 1788825600; # 2026-09-08T00:00:00Z
  vectorDebugFlakeTime = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;
in
{
  imports = [
    ../../modules/desktop/common-workstation.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/network-manager.nix
    ../../modules/desktop/niri.nix
    ../../modules/desktop/mic-mute.nix
    ../../modules/nix/nix-remote-builder-client.nix
    ./hardware-configuration.nix
  ];

  # The Arctis Nova Pro Wireless's hardware mic-mute reaches OS-level mute,
  # which silently breaks Discord mic input until manually unmuted. autoUnmute
  # is the workaround; monitor logs/notifies what is actually asserting it so
  # the workaround can be replaced with a real fix. Both expire 2026-11-01.
  # See modules/desktop/mic-mute.nix.
  homelab.audio.micMute.autoUnmute.enable = true;
  homelab.audio.micMute.monitor.enable = true;

  # Enable Xbox wireless dongle support
  hardware.xone.enable = true;

  # Add Xbox dongle firmware (append to existing firmware, don't replace)
  hardware.firmware = [ xone-dongle-firmware ];

  systemd.services.vector.environment.VECTOR_LOG = "warn,vector=debug";

  assertions = [{
    assertion = vectorDebugFlakeTime < vectorDebugDeadline;
    message = "wabbajack vector debug logging (VECTOR_LOG=warn,vector=debug) has expired (2026-09-08) - either root-cause the slow shutdown and remove it, or push the deadline out in hosts/wabbajack/configuration.nix";
  }];

  networking.hostName = "wabbajack";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

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
