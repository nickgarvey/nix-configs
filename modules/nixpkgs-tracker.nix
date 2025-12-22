{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixpkgs-tracker;

  trackerSrc = builtins.fetchTarball {
    url = "https://github.com/ocfox/nixpkgs-tracker/archive/refs/heads/master.tar.gz";
    sha256 = "1al9vimr2xfrqfn6mgl9fanj285n9iqq3vzc1hq6lxm7628a0hgs";
  };

  trackerPackage = pkgs.stdenv.mkDerivation rec {
    pname = "nixpkgs-tracker";
    version = "20251127";
    src = trackerSrc;

    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit pname version src;
      fetcherVersion = 2;
      hash = "sha256-2k1fWeU8VL6IHwReRbP40y/Q8JELl/2JefL8kjlENqc=";
    };

    nativeBuildInputs = with pkgs; [
      nodejs
      pnpm
      pnpmConfigHook
    ];

    buildPhase = "pnpm build";

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist $out/
      runHook postInstall
    '';
  };
in
{
  options.services.nixpkgs-tracker = {
    enable = lib.mkEnableOption "nixpkgs-tracker web service";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Port to serve nixpkgs-tracker on";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open firewall port for nixpkgs-tracker";
    };
  };

  config = lib.mkIf cfg.enable {
    # Decrypt the GitHub token using sops-nix
    sops.secrets.github-token = {
      sopsFile = ../secrets/github-token.yaml;
      key = "github_token";
    };

    systemd.services.nixpkgs-tracker = {
      description = "Nixpkgs PR Tracker";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        WorkingDirectory = "${trackerPackage}/dist";
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = 5;

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };

      # Make the GitHub token available (for future API proxy use)
      environment = {
        GITHUB_TOKEN_FILE = config.sops.secrets.github-token.path;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}

