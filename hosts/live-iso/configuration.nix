{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    ../../modules/nixos-common.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  networking.hostName = "nixos-live";

  nixpkgs.config.allowUnfree = true;

  # desktop-nixos has a Realtek 2.5G NIC that needs the out-of-tree r8125
  # driver (the in-tree r8169 won't bind, or binds unreliably). Bake it
  # into the live installer so the desktop can be installed/rescued
  # without sneakernet.
  boot.blacklistedKernelModules = [ "r8169" ];
  boot.extraModulePackages = with config.boot.kernelPackages; [ r8125 ];
  boot.kernelModules = [ "r8125" ];

  # Ensure sshd starts immediately (the ISO module may set startWhenNeeded)
  services.openssh = {
    enable = lib.mkForce true;
    settings.PermitRootLogin = "yes";
  };

  # Passwordless root console access (standard for installer ISOs)
  users.users.root = {
    initialHashedPassword = "";
    openssh.authorizedKeys.keys = config.users.users.ngarvey.openssh.authorizedKeys.keys;
  };

  environment.systemPackages = with pkgs; [
    # Disk partitioning and filesystem tools
    parted
    gptfdisk
    dosfstools
    e2fsprogs
    btrfs-progs
    ntfs3g
    cryptsetup

    # Network and transfer
    rsync
    curl

    # Hardware diagnostics
    smartmontools
    lshw
  ];

  # Ephemeral live system — no point running GC or optimise timers
  networking.firewall.enable = false;

  nix.gc.automatic = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;

  system.stateVersion = "25.05";
}
