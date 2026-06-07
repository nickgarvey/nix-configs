{ config, lib, pkgs, inputs, ... }:

{
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    package = pkgs.steam.override {
      extraPkgs = pkgs: with pkgs; [
        python3
      ];
    };
  };
}

