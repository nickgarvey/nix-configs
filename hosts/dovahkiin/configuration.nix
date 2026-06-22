{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/desktop/common-workstation.nix
    ../../modules/desktop/niri.nix
    ../../modules/networking/network-manager.nix
    ../../modules/desktop/steam.nix
    ../../modules/nix/nix-remote-builder-client.nix
    ../../modules/desktop/upower-overlay.nix
    ../../modules/desktop/opencloud-desktop.nix
    inputs.pi-nix.nixosModules.default
  ];

  # pi reads its env file as the ngarvey user, so the secret must be owned by it.
  sops.secrets.deepseek-api-key = {
    sopsFile = ../../secrets/deepseek.yaml;
    owner = "ngarvey";
  };

  programs.pi.coding-agent = {
    enable = true;
    environment.DEEPSEEK_API_KEY = config.sops.secrets.deepseek-api-key.path;
    extraArgs = [ "--provider" "deepseek" "--model" "deepseek-v4-pro" ];
  };

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "talos";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
    hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZcTP3OJYZenl8bb9fC9NTIvFCOaxs2gi1Mz4OhAByw";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "amdgpu.sg_display=0"
    "amdgpu.dcdebugmask=0x410"
    "amdgpu.cwsr_enable=0"
  ];

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  networking.hostName = "dovahkiin";
  networking.networkmanager.wifi.powersave = false;

  # The MT7925 (RZ717) Wi-Fi 7 firmware mailbox hangs when the PCIe link
  # enters ASPM L1, causing "Message ... timeout" firmware resets and dropped
  # connections. Disable L1 ASPM for just this device.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x0717", ATTR{link/l1_aspm}="0"
  '';

  # Framework 13 internal panel (13.5" 2256x1504). niri's auto-scale heuristic
  # picks 2.0 for this DPI, which is oversized; pin 1.5 instead.
  homelab.niri.outputs = ''
    output "eDP-1" {
        scale 1.5
    }
  '';

  homelab.niri.hasBattery = true;

  services.fwupd.enable = true;

  # The framework-amd-ai-300-series nixos-hardware profile enables fprintd by
  # default (lib.mkDefault), which adds pam_fprintd to the greetd login stack —
  # tuigreet then waits on a fingerprint swipe and blocks password entry. Disable
  # it: sudo is passwordless and there's no lock screen, so the reader is unused.
  services.fprintd.enable = false;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  users.users.ngarvey.packages = with pkgs; [
    signal-desktop
    vlc
    openmw
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "yes";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  system.stateVersion = "25.11";
}
