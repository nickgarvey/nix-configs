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

    binfmt.emulatedSystems = [ "aarch64-linux" ];
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

  homelab.niri.outputs = ''
    output "ASUSTek COMPUTER INC XG27UQDMS W3LMAV000673" {
        mode "3840x2160@240.000"
        scale 1.5
        position x=0 y=0
        variable-refresh-rate
    }
  '';

  users.users.ngarvey.packages = with pkgs; [
    rsync
  ];

  system.stateVersion = "25.11";
}
