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

    hostPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "SSH host public key of the remote builder. Pinned so root's nix-daemon can connect non-interactively without TOFU.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.nix-builder-ssh-key = {
      sopsFile = cfg.sshKeySopsFile;
      key = "nix_builder_ssh_key";
      mode = "0400";
      owner = "root";
    };

    programs.ssh.knownHosts.${cfg.hostName} = {
      hostNames = [ cfg.hostName "${cfg.hostName}.home.arpa" ];
      publicKey = cfg.hostPublicKey;
    };

    systemd.services.nix-daemon.environment.NIX_SSHOPTS = "-o ConnectTimeout=5 -o BatchMode=yes";

    nix.distributedBuilds = true;

    nix.buildMachines = [
      {
        hostName = cfg.hostName;
        systems = [ "x86_64-linux" "aarch64-linux" ];
        protocol = "ssh-ng";
        sshUser = "nix-builder";
        sshKey = config.sops.secrets.nix-builder-ssh-key.path;
        maxJobs = 4;
        speedFactor = 2;
        supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
      }
    ];

    nix.settings = {
      builders-use-substitutes = true;
      extra-substituters = [ "http://${cfg.hostName}:${toString cfg.cachePort}" ];
      extra-trusted-public-keys = [ cfg.cachePublicKey ];
      fallback = true;
      connect-timeout = 5;
      download-attempts = 1;
    };
  };
}
