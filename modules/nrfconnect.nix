{ pkgs, ... }:
{
  nixpkgs.config.segger-jlink.acceptLicense = true;

  environment.systemPackages = with pkgs; [
    nrfconnect
  ];
}
