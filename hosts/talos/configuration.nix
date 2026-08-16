{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/desktop/common-workstation.nix
    ../../modules/desktop/niri.nix
    ../../modules/networking/network-manager.nix
    ../../modules/nix/nix-remote-builder-client.nix
  ];

  networking = {
    hostName = "talos";
    hostId = "a4c946db";
  };

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    kernelModules = [ "nvidia" "nvidia_drm" "nvidia_uvm" "nvidia_modeset" ];

    # PCIe ASPM leaves the RTX 5090's link in a low-power state the driver
    # trips over; keep the link out of L0s/L1 entirely.
    kernelParams = [ "pcie_aspm=off" ];
  };

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = false;
    open = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # The RTX 5090 drives the display. xserver itself stays off (niri is a
  # Wayland compositor) — this only selects the DRM driver.
  services.xserver.videoDrivers = [ "nvidia" ];

  users.users.ngarvey.packages = with pkgs; [
    rsync
  ];

  system.stateVersion = "25.11";
}
