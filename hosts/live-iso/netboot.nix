# The live environment as PXE netboot artifacts, served by modules/services/netboot-server.nix.
{ lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
    ./common.nix
  ];

  # netboot-minimal strips redistributable firmware to keep the image small, but
  # Intel's xe driver needs GuC firmware to initialise: without it the driver
  # oopses in drm_connector_cleanup and the netbooted machine has no console —
  # exactly what you need when a netboot goes wrong. mkForce because
  # netboot-minimal sets this at mkOverride 70.
  hardware.enableRedistributableFirmware = lib.mkForce true;
}
