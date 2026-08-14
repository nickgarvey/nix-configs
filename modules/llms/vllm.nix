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
# The container runs in its own network namespace with a real, directly
# routable IPv6 address (homelab.vllm.address) in the host's delegated /64 —
# a veth pair into the configured bridge, the same mechanism the garage nspawn
# container uses for LAN presence. No NAT, no host port publish: the container
# is reachable directly at its own address.

let
  cfg = config.homelab.vllm;

  vllmUnit = "${config.virtualisation.oci-containers.containers.vllm.serviceName}.service";

  netnsName = "vllm";
  vethHost = "veth-vllm-h";
  vethCtr = "veth-vllm-c";

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
  options.homelab.vllm = {
    enable = lib.mkEnableOption "vLLM inference server (official docker image)";

    image = lib.mkOption {
      type = lib.types.str;
      # vllm/vllm-openai:v0.23.0 pinned by digest. Verified: transformers 5.12
      # (TokenizersBackend present), CUDA arch sm_120 (RTX 5090), runai s3
      # streamer bundled, native Qwen3.6 support (vLLM >= 0.17).
      default = "docker.io/vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f";
      description = "Container image (pinned by digest) to run.";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host bridge the container's veth is attached to, giving it LAN
        presence (e.g. "vmbr0" as set by homelab.network.bridge.name).
      '';
    };

    address = lib.mkOption {
      type = lib.types.str;
      description = ''
        IPv6 address the container listens on, from the host's delegated /64
        (the one carried on `bridge` via
        homelab.network.bridge.ipv6.extraAddresses). Treated as on-link in that
        /64 — the prefix length is appended by this module.
      '';
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
      default = "http://garage.home.garvey.sh:3900";
      description = "garage S3 endpoint. Resolves to both garage nodes.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "OpenAI-compatible API port vLLM listens on inside its own netns.";
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
      assertion = config.virtualisation.podman.enable;
      message = "homelab.vllm requires virtualisation.podman.enable = true.";
    }];

    # No networking.firewall rule needed: the LAN bridge is a trusted interface
    # (modules/networking/networkd.nix) and vLLM's netns is reached directly
    # at its own address, not via a port published on talos's own addresses.

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

    # nixpkgs has no declarative option for podman networks, so build a
    # netns + veth pair into vmbr0 by hand, ahead of the container. This is
    # the same mechanism nspawn uses for the garage container's LAN presence
    # (modules/containers/common.nix), just hand-rolled since podman has no
    # equivalent of nspawn's bridge attachment. Every step tolerates
    # re-running (idempotent across rebuilds/restarts).
    systemd.services.vllm-netns = {
      description = "Create the netns/veth network for vLLM (bridged onto ${cfg.bridge})";
      wantedBy = [ "multi-user.target" ];
      before = [ vllmUnit ];
      after = [ "sys-subsystem-net-devices-${cfg.bridge}.device" ];
      wants = [ "sys-subsystem-net-devices-${cfg.bridge}.device" ];
      path = [ pkgs.iproute2 pkgs.procps ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "vllm-netns-start" ''
          set -euo pipefail
          ip netns list | cut -d' ' -f1 | grep -qx ${netnsName} || ip netns add ${netnsName}
          ip link show ${vethHost} &>/dev/null || {
            ip link add ${vethHost} type veth peer name ${vethCtr}
            ip link set ${vethCtr} netns ${netnsName}
          }
          ip link set ${vethHost} master ${cfg.bridge}
          ip link set ${vethHost} up
          if ip netns exec ${netnsName} ip link show ${vethCtr} &>/dev/null; then
            ip netns exec ${netnsName} ip link set ${vethCtr} name eth0
          fi
          # autoconf=0: keep only our static address, no second SLAAC'd one.
          # accept_ra stays on (kernel default; set explicitly for clarity)
          # so eth0 learns on-link prefixes and RA-advertised routes exactly
          # like any other host on the bridge (including the site /48 route from
          # modules/router/lan-ipv6.nix) — a hand-rolled static route via the
          # host's own bridge address looks equivalent but is NOT: the host
          # treats the whole main-LAN /64 as on-link and answers NDP for it
          # directly rather than forwarding, which silently breaks delivery
          # to LAN hosts actually reached via the router. accept_ra_rt_info_max_plen
          # must be raised too — it's snapshotted from `default` (0) at
          # interface-creation time, same gotcha modules/containers/common.nix
          # documents for nspawn, so without it the /48 Route Information
          # Option is silently discarded as too specific.
          ip netns exec ${netnsName} sysctl -qw net.ipv6.conf.eth0.autoconf=0
          ip netns exec ${netnsName} sysctl -qw net.ipv6.conf.eth0.accept_ra=1
          ip netns exec ${netnsName} sysctl -qw net.ipv6.conf.eth0.accept_ra_rt_info_max_plen=64
          ip netns exec ${netnsName} ip link set lo up
          ip netns exec ${netnsName} ip link set eth0 up
          ip netns exec ${netnsName} ip -6 addr replace ${cfg.address}/64 dev eth0
        '';
      };
    };

    virtualisation.oci-containers = {
      backend = "podman";
      containers.vllm = {
        image = cfg.image;
        autoStart = true;
        cmd = cmd;
        # Join the netns built by vllm-netns.service above rather than a
        # podman-managed network — gives the container a real routable
        # address with no NAT/port-publish involved.
        networks = [ "ns:/var/run/netns/${netnsName}" ];
        # GPU via the nvidia-container-toolkit CDI device (`--gpus all` fails
        # with "AMD CDI spec not found" on NixOS — the CDI device name is what
        # works). --ipc=host: vLLM needs a large /dev/shm. --dns: with
        # --network=ns:<path>, podman doesn't manage DNS, so the container
        # inherits talos's own /etc/resolv.conf (Tailscale + IPv4 LAN
        # resolvers), neither reachable from this IPv6-only netns. Point it
        # at the site's real IPv6 resolver instead.
        extraOptions = [
          "--device=nvidia.com/gpu=all"
          "--ipc=host"
          "--dns=2001:470:482f::1"
        ];
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
      before = [ vllmUnit ];
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
          # Retry in place: garage lives on another host and may not be
          # reachable the instant network-online.target fires at boot. Staying
          # in `activating` (rather than failing) is what keeps systemd from
          # cancelling the dependent vllm start job. ~40 x 15s ~= 10 min, well
          # under TimeoutStartSec below.
          n=0
          max=40
          until ${pkgs.awscli2}/bin/aws --endpoint-url="${cfg.s3Endpoint}" --region=garage \
                s3 sync "${s3Uri}/" ${lib.escapeShellArg localPath} --delete; do
            n=$((n + 1))
            if [ "$n" -ge "$max" ]; then
              echo "vllm-model-sync: giving up after $n attempts" >&2
              exit 1
            fi
            echo "vllm-model-sync: sync failed (attempt $n/$max), retrying in 15s..." >&2
            sleep 15
          done
        '';
        Restart = "on-failure";
        RestartSec = 30;
        TimeoutStartSec = "3600";
      };
    };

    # First start pulls the (multi-GB) image; give it room. In local mode the
    # container also waits for the model sync.
    systemd.services."${config.virtualisation.oci-containers.containers.vllm.serviceName}" = {
      serviceConfig.TimeoutStartSec = lib.mkForce "1800";
      after = [ "vllm-netns.service" ];
      requires = [ "vllm-netns.service" ];
    } // lib.optionalAttrs (cfg.loadFormat == "local") {
      after = [ "vllm-netns.service" "vllm-model-sync.service" ];
      requires = [ "vllm-netns.service" "vllm-model-sync.service" ];
    };
  };
}
