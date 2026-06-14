{ config, lib, pkgs, ... }:

# vLLM OpenAI-compatible inference server, run from the official
# `vllm/vllm-openai` container image. The image ships vLLM with CUDA arch 12.0
# (RTX 5090 / sm_120) and bundles `runai-model-streamer[s3,gcs]`.
#
# Models live in the garage `llm-models` S3 bucket (pushed there with the
# hf-to-garage tool). vLLM loads them by streaming directly from S3 with the
# run:ai model streamer (loadFormat = "runai_streamer", default), or by syncing
# the bucket to a local dir and bind-mounting it (loadFormat = "local").
#
# The garage S3 endpoint is IPv6-only. We enable IPv6 on the docker bridge
# (virtualisation.docker.daemon.settings in the talos config) and reach garage
# by its static IPv6 literal — Docker's embedded DNS + systemd-resolved don't
# play nicely with split-horizon .home.arpa names, and the literal avoids that
# entirely (garage is only the model store, so it's the one endpoint we need).

let
  cfg = config.homelab.vllmDocker;

  s3Uri = "s3://${cfg.bucket}/${cfg.model}";
  localPath = "${cfg.localModelsDir}/${cfg.model}";
  isStreamer = cfg.loadFormat == "runai_streamer";

  # boto3 env for talking to garage (S3-compatible, path-style, http).
  s3Env = {
    AWS_ENDPOINT_URL = cfg.s3Endpoint;
    AWS_REGION = "garage";
    RUNAI_STREAMER_S3_USE_VIRTUAL_ADDRESSING = "0";
    AWS_EC2_METADATA_DISABLED = "true";
    # garage rejects the default CRC checksum recent boto3/awscli adds.
    AWS_REQUEST_CHECKSUM_CALCULATION = "when_required";
    AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required";
  };

  serveModel = if isStreamer then s3Uri else "/model";

  cmd = [
    "--model" serveModel
    "--served-model-name" "vllm"
    "--host" "::"
    "--port" "8000"
  ] ++ lib.optionals isStreamer [ "--load-format" "runai_streamer" ]
    ++ cfg.extraArgs;
in
{
  options.homelab.vllmDocker = {
    enable = lib.mkEnableOption "vLLM inference server (official docker image)";

    image = lib.mkOption {
      type = lib.types.str;
      # vllm/vllm-openai:v0.23.0 pinned by digest. Verified: transformers 5.12
      # (TokenizersBackend present), CUDA arch sm_120 (RTX 5090), runai s3
      # streamer bundled, native Qwen3.6 support (vLLM >= 0.17).
      default = "vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f";
      description = "Container image (pinned by digest) to run.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      description = ''
        Model key inside the garage bucket, i.e. the <name> in
        s3://<bucket>/<name>/ that hf-to-garage uploaded (e.g. "LFM2.5-VL-450M").
      '';
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      default = "llm-models";
      description = "garage bucket holding the models.";
    };

    s3Endpoint = lib.mkOption {
      type = lib.types.str;
      # garage-tarrasque's static LAN IPv6 (talos-local garage node). Literal,
      # not the .home.arpa name, because docker's DNS can't resolve it — see
      # the module header.
      default = "http://[2001:470:482f:201::2]:3900";
      description = "garage S3 endpoint (talos-local garage node by default).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "OpenAI-compatible API port (bound on the host via --network=host).";
    };

    loadFormat = lib.mkOption {
      type = lib.types.enum [ "runai_streamer" "local" ];
      default = "runai_streamer";
      description = ''
        "runai_streamer": stream weights straight from garage S3.
        "local": sync the bucket to localModelsDir first and bind-mount it
        (fallback for models the streamer mishandles, e.g. some VL processors).
      '';
    };

    localModelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/models";
      description = "Host dir for loadFormat = \"local\" syncs (bind-mounted at /model).";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra flags appended to the vLLM server command.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.virtualisation.docker.enable;
      message = "homelab.vllmDocker requires virtualisation.docker.enable = true.";
    }];

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Root-owned creds template (system service), separate from the
    # ngarvey-owned one the workstation hf-to-garage tool uses. Passed into the
    # container as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
    sops.secrets.vllm-s3-access-key = {
      sopsFile = ../../secrets/llm-models.yaml;
      key = "llm_models_s3_access_key";
    };
    sops.secrets.vllm-s3-secret-key = {
      sopsFile = ../../secrets/llm-models.yaml;
      key = "llm_models_s3_secret_key";
    };
    sops.templates."vllm-s3.env".content = ''
      AWS_ACCESS_KEY_ID=${config.sops.placeholder.vllm-s3-access-key}
      AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.vllm-s3-secret-key}
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/vllm 0750 root root - -"
      "d /var/lib/vllm/hf 0750 root root - -"
    ] ++ lib.optional (cfg.loadFormat == "local")
      "d ${cfg.localModelsDir} 0755 root root - -";

    virtualisation.oci-containers = {
      backend = "docker";
      containers.vllm = {
        image = cfg.image;
        autoStart = true;
        cmd = cmd;
        ports = [ "${toString cfg.port}:8000" ];
        # GPU via the nvidia-container-toolkit CDI device (the docker daemon
        # runs in CDI mode on NixOS — `--gpus all` fails with "AMD CDI spec not
        # found", the CDI device name is what works). --ipc=host: vLLM needs a
        # large /dev/shm. IPv6 reach to garage comes from the docker daemon's
        # IPv6 bridge (configured on the host), not from host networking.
        extraOptions = [ "--device=nvidia.com/gpu=all" "--ipc=host" ];
        # NB: do NOT set HF_HUB_OFFLINE — it forces vLLM's offline path
        # resolver, which can't parse s3:// URIs and crashes. For an s3 model
        # vLLM pulls config/tokenizer from garage via the runai streamer.
        environment = lib.optionalAttrs isStreamer s3Env // {
          HF_HOME = "/root/.cache/huggingface";
        };
        environmentFiles = lib.optional isStreamer
          config.sops.templates."vllm-s3.env".path;
        volumes = [ "/var/lib/vllm/hf:/root/.cache/huggingface" ]
          ++ lib.optional (cfg.loadFormat == "local") "${localPath}:/model:ro";
      };
    };

    # loadFormat = "local": pull the model from garage before the container.
    systemd.services.vllm-model-sync = lib.mkIf (cfg.loadFormat == "local") {
      description = "Sync ${cfg.model} from garage to ${localPath}";
      wantedBy = [ "multi-user.target" ];
      before = [ "docker-vllm.service" ];
      after = [ "network-online.target" "nss-lookup.target" ];
      wants = [ "network-online.target" "nss-lookup.target" ];
      environment = s3Env;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = config.sops.templates."vllm-s3.env".path;
        ExecStart = pkgs.writeShellScript "vllm-model-sync" ''
          set -euo pipefail
          mkdir -p ${lib.escapeShellArg localPath}
          exec ${pkgs.awscli2}/bin/aws --endpoint-url="${cfg.s3Endpoint}" --region=garage \
            s3 sync "${s3Uri}/" ${lib.escapeShellArg localPath} --delete
        '';
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

    # First start pulls the (multi-GB) image; give it room.
    systemd.services.docker-vllm.serviceConfig.TimeoutStartSec = lib.mkForce "1800";
  };
}
