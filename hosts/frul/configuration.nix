{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/k3s/k3s-common.nix
    ../../modules/k3s/kata.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/thunderbolt-mesh.nix
    ../../modules/services/ceph.nix
  ];

  networking.hostName = "frul";

  # Worker only: the control plane (and etcd) stays on fus/ro/dah.
  services.k3s.role = "agent";

  # The newest stable kernel for this Wildcat Lake box (AZW EQi): better
  # platform support (xe graphics, USB4, power management) than the 6.18 LTS.
  # joor, zah and frul run the same kernel; the Thunderbolt mesh has only been
  # seen to misbehave between mixed kernels.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Diagnostics (nix-k2KT9.20): frul hangs after systemd reaches the reboot
  # target and never resets. initcall_debug makes the kernel log each device's
  # shutdown callback, and loglevel=7 puts those lines on the console, so a
  # hang leaves the stuck driver as the last line on screen.
  boot.kernelParams = [ "initcall_debug" "loglevel=7" ];
  assertions = [{
    assertion = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified < 1793491200; # 2026-11-01T00:00:00Z
    message = ''
      frul's reboot-hang diagnostics (nix-k2KT9.20) expired on 2026-11-01.
      Either the stuck driver was found and fixed (delete the kernelParams and
      this assertion in hosts/frul/configuration.nix) or it was not and the
      deadline needs pushing out deliberately.
    '';
  }];
}
