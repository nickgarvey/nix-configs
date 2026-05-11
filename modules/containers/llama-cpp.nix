{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.llama-cpp;

  llamaPackages = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system};

  gpuConfig = {
    vulkan = {
      bindMounts = {
        "/run/opengl-driver" = { hostPath = "/run/opengl-driver"; isReadOnly = true; };
      };
      allowedDevices = [
        { node = "/dev/dri/renderD128"; modifier = "rwm"; }
        { node = "/dev/dri/card1";      modifier = "rwm"; }
      ];
      extraFlags = [ "--bind=/dev/dri" ];
      extraSystemPackages = [ pkgs.vulkan-tools ];
    };
    cuda = {
      bindMounts = {
        "/run/opengl-driver" = { hostPath = "/run/opengl-driver"; isReadOnly = true; };
      };
      allowedDevices = [
        { node = "/dev/nvidia0";          modifier = "rwm"; }
        { node = "/dev/nvidiactl";        modifier = "rwm"; }
        { node = "/dev/nvidia-uvm";       modifier = "rwm"; }
        { node = "/dev/nvidia-uvm-tools"; modifier = "rwm"; }
        { node = "/dev/nvidia-modeset";   modifier = "rwm"; }
      ];
      extraFlags = [
        "--bind=/dev/nvidia0"
        "--bind=/dev/nvidiactl"
        "--bind=/dev/nvidia-uvm"
        "--bind=/dev/nvidia-uvm-tools"
        "--bind=/dev/nvidia-modeset"
      ];
      extraSystemPackages = [ ];
    };
    cpu = {
      bindMounts = { };
      allowedDevices = [ ];
      extraFlags = [ ];
      extraSystemPackages = [ ];
    };
  };

  selectedGpu = gpuConfig.${cfg.backend};
  selectedPkg = llamaPackages.${cfg.backend};

  llamaArgs = lib.concatStringsSep " " ([
    "--host ::"
    "--port 8080"
    "--ctx-size 65536"
    "--metrics"
    "--batch-size 4096"
    "--ubatch-size 512"
    "--jinja"
    "--timeout 1800"
    # Stable API-facing name decoupled from the GGUF filename, so consumers
    # (e.g. trmnl-display) don't need updating when the model changes.
    "--alias llama-cpp"
  ] ++ lib.optional (cfg.backend != "cpu") "--n-gpu-layers 99"
    ++ cfg.extraArgs);
in
{
  options.homelab.llama-cpp = {
    enable = lib.mkEnableOption "llama-cpp inference server container";

    backend = lib.mkOption {
      type = lib.types.enum [ "vulkan" "cuda" "cpu" ];
      description = "llama-cpp build and matching GPU device passthrough.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra flags appended to llama-server (e.g. sampling overrides).";
    };

    models = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name   = lib.mkOption { type = lib.types.str; };
          repo   = lib.mkOption { type = lib.types.str; };
          filter = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        };
      });
      description = "Models to download from HuggingFace and serve.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /models 0755 root root - -" ];

    networking.firewall.allowedTCPPorts = [ 8080 ];

    containers.llama-cpp = {
      autoStart = true;
      privateNetwork = false;

      # First-boot model downloads can take much longer than the 1min default;
      # the container stays in `activating` until inner multi-user.target reaches
      # ready, which is gated on llama-cpp-download.service.
      timeoutStartSec = "1h";

      bindMounts = {
        "/models" = { hostPath = "/models"; isReadOnly = false; };
      } // selectedGpu.bindMounts;

      allowedDevices = selectedGpu.allowedDevices;
      extraFlags     = selectedGpu.extraFlags;

      config = { pkgs, ... }: {
        environment.systemPackages = [ selectedPkg pkgs.python3 ] ++ selectedGpu.extraSystemPackages;

        systemd.services.llama-cpp-download = {
          description = "Download GGUF models for llama-cpp";
          wantedBy = [ "multi-user.target" ];
          before   = [ "llama-cpp-server.service" ];
          # DNS must be ready: container has its own /etc/resolv.conf pointing
          # at host's systemd-resolved; without these waits, boot-time download
          # races resolved and fails with "Name or service not known".
          after    = [ "network-online.target" "nss-lookup.target" ];
          wants    = [ "network-online.target" "nss-lookup.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${./llama-cpp-download-models.py}";
            TimeoutStartSec = "1h";
          };
          environment.MODELS_CONFIG = builtins.toJSON cfg.models;
        };

        systemd.services.llama-cpp-server = {
          description = "llama.cpp inference server";
          wantedBy = [ "multi-user.target" ];
          # `wants` (not `requires`): if the download retry fails (e.g. DNS
          # race against the host's resolved, which has happened on boot),
          # still bring up the server against whatever GGUFs are already on
          # /models. The ExecStart script errors out if none exist.
          after    = [ "llama-cpp-download.service" "network-online.target" ];
          wants    = [ "llama-cpp-download.service" "network-online.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = pkgs.writeShellScript "llama-cpp-start" ''
              set -euo pipefail
              shopt -s nullglob
              files=(/models/*/*.gguf)
              if [ ''${#files[@]} -eq 0 ]; then
                echo "ERROR: no .gguf model found under /models/" >&2
                exit 1
              fi
              MODEL="''${files[0]}"
              echo "starting llama-server with model: $MODEL"
              exec ${selectedPkg}/bin/llama-server --model "$MODEL" ${llamaArgs}
            '';
            Restart = "on-failure";
            RestartSec = 10;
          };
        };

        networking.firewall.enable = false;

        system.stateVersion = "25.05";
      };
    };
  };
}
