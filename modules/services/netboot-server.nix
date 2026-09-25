# PXE boot server (pixiecore) offering the live-netboot rescue/install system to the LAN.
{ config, lib, pkgs, inputs, ... }:

let
  live = inputs.self.nixosConfigurations.live-netboot.config;

  kernel = "${live.system.build.kernel}/${live.boot.kernelPackages.kernel.target}";
  initrd = "${live.system.build.netbootRamdisk}/initrd";

  # Same command line the generated netboot.ipxe script would use.
  cmdLine = lib.concatStringsSep " " (
    [ "init=${live.system.build.toplevel}/init" ] ++ live.boot.kernelParams
  );
in
{
  # pixiecore answers as proxyDHCP: it supplies boot information only and never
  # hands out addresses, so the router keeps owning DHCP
  # (modules/router/dhcp.nix) and its static-lease table is untouched. It also
  # carries both BIOS and UEFI iPXE binaries, which a single networkd
  # BootFilename= could not select between.
  #
  # The live system is referenced by store path, so it is part of this host's
  # closure: a change under hosts/live-iso/ means rebuilding and redeploying
  # this host before the new live environment is served.
  services.pixiecore = {
    enable = true;
    mode = "boot";
    inherit kernel initrd cmdLine;

    # 80 is the module default and too likely to collide with a real web
    # service; the port only has to match what pixiecore puts in its own iPXE
    # script, which it generates.
    port = 8880;
    statusPort = 8880;

    # 67/4011 udp (proxyDHCP), 69 udp (TFTP), 8880 tcp (kernel/initrd + status).
    openFirewall = true;
  };
}
