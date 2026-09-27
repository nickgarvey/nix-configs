{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/k3s/k3s-common.nix
    ../../modules/k3s/kata.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/thunderbolt-mesh.nix
    ../../modules/services/ceph.nix
    # Backs up every Ceph RBD volume; one node is enough.
    ../../modules/services/ceph-backup.nix
  ];

  networking.hostName = "joor";

  # Worker only: the control plane (and etcd) stays on fus/ro/dah.
  services.k3s.role = "agent";
}
