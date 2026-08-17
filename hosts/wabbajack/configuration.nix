{ config, lib, pkgs, inputs, ... }:
# Framework Desktop (AMD Ryzen AI MAX+ 395) running headless as a server.
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/core/nixos-common.nix
    ../../modules/networking/networkd.nix
    ../../modules/containers/garage.nix
  ];

  networking.hostName = "wabbajack";
  homelab.network.enable = true;
  # Required so the garage container (on vmbr0) can route to its peer's
  # delegated /64 — crosses interfaces, needs IPv6 forwarding.
  homelab.network.ipv6Forward = true;

  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  # Bridge for the garage nspawn container to get LAN access (IPv6 auto-derived
  # from lan-hosts.nix). Mirrors lydia's setup.
  homelab.network.bridge = {
    name = "vmbr0";
    interface = "enp191s0";
    ipv4 = {
      address = "10.28.1.10/16";
      gateway = "10.28.0.1";
    };
    # wabbajack's own LAN identity is the static 2001:470:482f::10
    # (lan-hosts.nix). suppressSlaac stops networkd adding a second, dynamic
    # LAN-/64 address on top of it.
    ipv6.suppressSlaac = true;
    # The garage container lives in the delegated 2001:470:482f:202::/64.
    # Carry that /64's gateway on vmbr0 so the container's hostBridgeAddress
    # next-hop resolves and the router's on-link route for the /64
    # (modules/router/lan-ipv6.nix) NDP-resolves to us.
    ipv6.extraAddresses = [ "2001:470:482f:202::1/64" ];
  };

  fileSystems."/fast/garage" = {
    device = "/dev/disk/by-label/fast";
    fsType = "btrfs";
    options = [ "compress=zstd" "subvol=@garage" "nofail" ];
  };

  # --- Garage S3 (nspawn container, IPv6-only) ---
  # Second node of the two-node RF=2 cluster; lydia runs the other (aboleth).
  nspawn.garage = {
    hostBridge = "vmbr0";
    localAddress6 = "2001:470:482f:202::2/64";
    hostBridgeAddress = "2001:470:482f:202::1";
    dataPath = "/fast/garage";
    hostname = "wabbajack";
    capacity = "1.5T";
    replicationFactor = 2;
    peers = [ "1f19395c7b916da44c6acff1a831ddbf7fc294a020b071704f04b6d17a0277dc@[2001:470:482f:200::2]:3901" ];
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Pinned so /home ownership stays stable across reinstalls.
  users.users.ngarvey.uid = 1000;

  system.stateVersion = "25.11";
}
