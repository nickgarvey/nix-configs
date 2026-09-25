# The live environment as a bootable ISO image.
{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    ./common.nix
  ];
}
