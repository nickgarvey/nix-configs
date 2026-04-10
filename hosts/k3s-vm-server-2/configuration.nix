{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/k3s-common.nix
    ../../modules/nixos-common.nix
  ];

  networking.hostName = "k3s-vm-server-2";

  services.k3s.role = "server";

  # Persist SSH host keys on the /var volume so the VM has a stable identity
  # across reboots (rootfs is a tmpfs by default in microvm.nix).
  services.openssh.hostKeys = [
    { path = "/var/lib/sshd/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/var/lib/sshd/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
  ];
}
