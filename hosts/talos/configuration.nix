{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/desktop/common-workstation.nix
    ../../modules/desktop/niri.nix
    ../../modules/networking/network-manager.nix
    ../../modules/nix/nix-remote-builder-client.nix
    ../../modules/desktop/proton-ge-wc3.nix
  ];

  networking = {
    hostName = "talos";
    hostId = "a4c946db";

    # ThinkRail's engine host, started by hand with `thinkrail --host ::`.
    firewall.allowedTCPPorts = [ 24242 ];
    firewall.allowedTCPPortRanges = [ { from = 8280; to = 8289; } ];
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

  # Exposes the GPU to containers as the CDI device `nvidia.com/gpu=all`
  # (`docker run --device=nvidia.com/gpu=all ...`). `--gpus all` does not work:
  # the NixOS module wires CDI only, it installs no nvidia OCI runtime.
  hardware.nvidia-container-toolkit.enable = true;

  # The RTX 5090 drives the display. xserver itself stays off (niri is a
  # Wayland compositor) — this only selects the DRM driver.
  services.xserver.videoDrivers = [ "nvidia" ];

  # The local ninfer llama server runs here (RTX 5090), so pi is given its
  # provider and can be pointed at it. DeepSeek stays the default model.
  homelab.pi.ninfer.enable = true;

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
