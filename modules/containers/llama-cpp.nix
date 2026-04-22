{ config, lib, pkgs, inputs, ... }:

let
  llama-cpp-vulkan = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.default;

  modelsConfig = builtins.toJSON [
    {
      name = "qwen3.5-27b";
      repo = "unsloth/Qwen3.5-27B-GGUF";
      filter = "UD-Q4_K_XL";
    }
    {
      name = "qwen3.5-9b";
      repo = "unsloth/Qwen3.5-9B-GGUF";
      filter = "UD-Q4_K_XL";
    }
    {
      name = "qwen3.5-4b";
      repo = "unsloth/Qwen3.5-4B-GGUF";
      filter = "UD-Q4_K_XL";
    }
  ];

  llamaArgs = lib.concatStringsSep " " [
    "--host ::"
    "--port 8080"
    "--n-gpu-layers 99"
    "--ctx-size 65536"
    "--metrics"
    "--batch-size 4096"
    "--ubatch-size 512"
    "--jinja"
    "--models-max 4"
    "--timeout 1800"
    "--models-dir /models"
  ];

  downloadScript = ./llama-cpp-download-models.py;
in
{
  # Ensure /models directory exists on the host
  systemd.tmpfiles.rules = [
    "d /models 0755 root root - -"
  ];

  # Open port 8080 for llama-cpp API
  networking.firewall.allowedTCPPorts = [ 8080 ];

  containers.llama-cpp = {
    autoStart = true;
    privateNetwork = false;

    bindMounts = {
      "/models" = {
        hostPath = "/models";
        isReadOnly = false;
      };
      "/run/opengl-driver" = {
        hostPath = "/run/opengl-driver";
        isReadOnly = true;
      };
    };

    allowedDevices = [
      { node = "/dev/dri/renderD128"; modifier = "rwm"; }
      { node = "/dev/dri/card1"; modifier = "rwm"; }
    ];
    extraFlags = [ "--bind=/dev/dri" ];

    config = { config, pkgs, lib, ... }: {
      environment.systemPackages = [
        llama-cpp-vulkan
        pkgs.python3
        pkgs.vulkan-tools
      ];

      # Model download service (runs before llama-server)
      systemd.services.llama-cpp-download = {
        description = "Download GGUF models for llama-cpp";
        wantedBy = [ "multi-user.target" ];
        before = [ "llama-cpp-server.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.python3}/bin/python3 ${downloadScript}";
          TimeoutStartSec = "1h";
        };
        environment = {
          MODELS_CONFIG = modelsConfig;
        };
      };

      # llama-server service
      systemd.services.llama-cpp-server = {
        description = "llama.cpp inference server";
        wantedBy = [ "multi-user.target" ];
        after = [ "llama-cpp-download.service" "network-online.target" ];
        requires = [ "llama-cpp-download.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${llama-cpp-vulkan}/bin/llama-server ${llamaArgs}";
          Restart = "on-failure";
          RestartSec = 10;
        };
      };

      networking.firewall.enable = false;

      system.stateVersion = "25.05";
    };
  };
}
