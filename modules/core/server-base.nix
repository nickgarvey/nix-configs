# Baseline for headless servers on the homelab LAN: systemd-networkd, systemd-boot, sops YAML.
{ ... }:
{
  imports = [ ../networking/networkd.nix ];

  homelab.network.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  sops.defaultSopsFormat = "yaml";
}
