{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/steam.nix
    ../../modules/esp-prog-udev.nix
    ../../modules/wifi.nix
    # ../../modules/vector-db-learning.nix  # disabled: arxiv pins requests~=2.32, conflicts with nixpkgs 2.33
    ../../modules/nix-remote-builder-client.nix
  ];

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "tarrasque";
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
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

  networking.hostName = "framework13-laptop";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;

  services.fwupd.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  users.users.ngarvey.packages = with pkgs; [
    vlc
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "yes";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  system.stateVersion = "25.11"; # Do not change!
}
