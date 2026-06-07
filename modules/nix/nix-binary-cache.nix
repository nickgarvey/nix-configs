{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixBinaryCache;
in
{
  options.services.nixBinaryCache = {
    enable = lib.mkEnableOption "nix binary cache server and remote build acceptance";

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "SSH public keys authorized to submit remote builds as nix-builder.";
    };

    signingKeySopsFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the sops secrets file containing the nix-serve signing key (key: nix_serve_signing_key).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.nix-serve-signing-key = {
      sopsFile = cfg.signingKeySopsFile;
      key = "nix_serve_signing_key";
    };

    users.users.nix-builder = {
      isSystemUser = true;
      group = "nix-builder";
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    users.groups.nix-builder = {};

    nix.settings.trusted-users = [ "nix-builder" ];

    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ config.sops.secrets.nix-serve-signing-key.path ];
      settings = {
        bind = "[::]:5000";
        priority = 30;
      };
    };

    networking.firewall.allowedTCPPorts = [ 5000 ];
  };
}
