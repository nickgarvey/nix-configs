{ config, lib, ... }:

let
  cfg = config.services.nixRemoteBuilderClient;
in
{
  options.services.nixRemoteBuilderClient = {
    enable = lib.mkEnableOption "remote nix builder and binary cache client";

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Hostname of the remote builder (e.g. Tailscale MagicDNS name).";
    };

    cachePublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Public signing key for the remote nix binary cache.";
    };

    sshKeySopsFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the sops secrets file containing the builder SSH private key (key: nix_builder_ssh_key).";
    };

    cachePort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port the remote nix-serve instance listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.nix-builder-ssh-key = {
      sopsFile = cfg.sshKeySopsFile;
      key = "nix_builder_ssh_key";
      mode = "0400";
      owner = "root";
    };

    nix.distributedBuilds = true;

    nix.buildMachines = [
      {
        hostName = cfg.hostName;
        systems = [ "x86_64-linux" ];
        protocol = "ssh-ng";
        sshUser = "nix-builder";
        sshKey = config.sops.secrets.nix-builder-ssh-key.path;
        maxJobs = 4;
        speedFactor = 2;
        supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
      }
    ];

    nix.settings = {
      extra-substituters = [ "http://${cfg.hostName}:${toString cfg.cachePort}" ];
      extra-trusted-public-keys = [ cfg.cachePublicKey ];
    };
  };
}
