{ config, lib, pkgs, ... }:

# hf-to-garage: a manual tool for pushing a HuggingFace repo into the garage
# `llm-models` S3 bucket, which is the model store the vLLM service on talos
# loads from. The user runs this by hand from a workstation:
#
#     hf-to-garage LiquidAI/LFM2.5-VL-450M
#     hf-to-garage <org/repo> [revision]
#
# It downloads the full HF repo layout (config.json, *.safetensors, tokenizer
# + processor files, chat template) and `aws s3 sync`s it to
# s3://llm-models/<repo-basename>/ — the layout vLLM's run:ai streamer expects.
#
# Lives in modules/llms/ but is wired in via modules/desktop/common-workstation.nix
# so every workstation (not talos) gets it. Credentials come from the dedicated
# `llm-models` garage key in secrets/llm-models.yaml, rendered to a sops template
# owned by `ngarvey` so the (non-root) user running the tool can read it.

let
  cfg = config.homelab.hfToGarage;
in
{
  options.homelab.hfToGarage = {
    enable = lib.mkEnableOption "hf-to-garage HuggingFace → garage upload tool";

    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://garage-aboleth.home.arpa:3900";
      description = "garage S3 endpoint URL (reachable over LAN IPv6 when on-network).";
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      default = "llm-models";
      description = "Destination bucket. Models land at s3://<bucket>/<repo-basename>/.";
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "garage";
      description = "Region string. Garage ignores it but awscli requires one.";
    };

    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/tmp";
      description = ''
        Parent directory for the temporary download (models are multi-GB, so
        not /tmp which is often tmpfs). A mktemp subdir here is removed on exit.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # huggingface-hub provides the `hf` CLI; hf-transfer is the optional
      # accelerator enabled via HF_HUB_ENABLE_HF_TRANSFER=1. Both must live in
      # ONE python env so the CLI's interpreter can import hf_transfer.
      hfEnv = pkgs.python3.withPackages (ps: [
        ps.huggingface-hub
        ps.hf-transfer
      ]);

      credsFile = config.sops.templates."llm-models-s3.env".path;

      hf-to-garage = pkgs.writeShellApplication {
        name = "hf-to-garage";
        runtimeInputs = [ hfEnv pkgs.awscli2 pkgs.coreutils ];
        text = ''
          set -euo pipefail

          if [ "$#" -lt 1 ]; then
            echo "usage: hf-to-garage <hf-repo-id> [revision]" >&2
            echo "  e.g. hf-to-garage LiquidAI/LFM2.5-VL-450M" >&2
            exit 1
          fi

          REPO="$1"
          REV="''${2:-main}"
          NAME="$(basename "$REPO")"

          CREDS="${credsFile}"
          if [ ! -r "$CREDS" ]; then
            echo "error: cannot read $CREDS" >&2
            echo "  (need the llm-models sops secret; run as the user that owns it)" >&2
            exit 1
          fi
          # shellcheck disable=SC1090
          . "$CREDS"
          export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
          export AWS_EC2_METADATA_DISABLED=true
          export HF_HUB_ENABLE_HF_TRANSFER=1

          # Recent AWS CLI v2 adds a default CRC checksum to (multipart) uploads,
          # which garage rejects with "invalid checksum algorithm". Only send
          # checksums when the operation actually requires one.
          export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
          export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

          TMP="$(mktemp -d "${cfg.workDir}/hf-to-garage.XXXXXX")"
          trap 'rm -rf "$TMP"' EXIT

          echo ">> downloading $REPO (revision $REV) -> $TMP"
          hf download "$REPO" --revision "$REV" --local-dir "$TMP"

          echo ">> syncing to s3://${cfg.bucket}/$NAME/"
          aws --endpoint-url="${cfg.endpoint}" --region="${cfg.region}" \
            s3 sync "$TMP" "s3://${cfg.bucket}/$NAME/" \
            --delete --exclude '.cache/*'

          echo ">> done: s3://${cfg.bucket}/$NAME/"
        '';
      };
    in
    {
      sops.secrets.llm-models-s3-access-key = {
        sopsFile = ../../secrets/llm-models.yaml;
        key = "llm_models_s3_access_key";
      };
      sops.secrets.llm-models-s3-secret-key = {
        sopsFile = ../../secrets/llm-models.yaml;
        key = "llm_models_s3_secret_key";
      };

      # Owned by the interactive user so the manually-run tool can read it.
      sops.templates."llm-models-s3.env" = {
        owner = "ngarvey";
        content = ''
          AWS_ACCESS_KEY_ID=${config.sops.placeholder.llm-models-s3-access-key}
          AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.llm-models-s3-secret-key}
        '';
      };

      environment.systemPackages = [ hf-to-garage ];
    }
  );
}
