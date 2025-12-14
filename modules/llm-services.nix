{ config, lib, pkgs, ... }:
{
  nixpkgs.overlays = [
    (import ../overlays/outlines-no-check.nix)
  ];

  services.open-webui = {
    enable = true;
    port = 8080;
    environment = {
      OPENAI_API_BASE_URL = "http://localhost:8000/v1";
    };
  };

  environment.systemPackages = [
    pkgs.python3Packages.vllm
  ];
}

