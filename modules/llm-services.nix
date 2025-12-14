{ config, lib, pkgs, ... }:

let
  cfg = config.services.vllm;
in
{
  options.services.vllm = {
    enable = lib.mkEnableOption "vLLM OpenAI-compatible API server";

    model = lib.mkOption {
      type = lib.types.str;
      default = "Qwen/Qwen3-14B";
      description = "The model to serve (e.g., Qwen/Qwen3-14B)";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port to listen on";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Host address to bind to";
    };

    dtype = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Data type for model weights (auto, float16, bfloat16, float32)";
    };

    gpuMemoryUtilization = lib.mkOption {
      type = lib.types.str;
      default = "0.80";
      description = "Fraction of GPU memory to use (0.0 to 1.0)";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra arguments to pass to vllm serve";
      example = [ "--max-model-len" "4096" ];
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3Packages.vllm;
      description = "The vLLM package to use";
    };
  };

  config = lib.mkMerge [
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

    (lib.mkIf cfg.enable {
      # Create dedicated vLLM user
      users.users.vllm = {
        isSystemUser = true;
        group = "vllm";
        home = "/var/lib/vllm";
        createHome = true;
        extraGroups = [ "render" ];  # GPU access
      };

      users.groups.vllm = {};

      systemd.services.vllm = {
        description = "vLLM OpenAI-compatible API server";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = lib.concatStringsSep " " ([
            "${cfg.package}/bin/vllm"
            "serve"
            cfg.model
            "--host" cfg.host
            "--port" (toString cfg.port)
            "--dtype" cfg.dtype
            "--gpu-memory-utilization" cfg.gpuMemoryUtilization
          ] ++ cfg.extraArgs);
          Restart = "on-failure";
          RestartSec = "10s";

          # Run as dedicated vLLM user (needs GPU access and writable cache for Triton compilation)
          User = "vllm";
          Group = "vllm";

          # Environment for HuggingFace cache and PyTorch CUDA memory management
          Environment = [
            "HF_HOME=/var/lib/vllm/.cache/huggingface"
            "PYTORCH_ALLOC_CONF=expandable_segments:True"
          ];
        };
      };
    })
  ];
}
