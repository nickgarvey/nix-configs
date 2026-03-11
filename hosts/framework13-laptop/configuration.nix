{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common-workstation.nix
    ../../modules/steam.nix
    ../../modules/nix-remote-builder-client.nix
    ../../modules/esp-prog-udev.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  networking.hostName = "framework13-laptop";

  services.fwupd.enable = true;

  services.nixRemoteBuilderClient = {
    enable = true;
    hostName = "desktop-nixos.bigeye-turtle.ts.net";
    sshKeySopsFile = ../../secrets/nix-builder.yaml;
    cachePublicKey = "desktop-nixos-cache:dwK3Z7fL5Kfd3AMiWJhkKI1hSh5M8mm5nGeYeG2mSdE=";
  };

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
