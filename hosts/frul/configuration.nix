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
}
