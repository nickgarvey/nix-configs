{ config, lib, pkgs, inputs, ... }:

# pi, a terminal coding agent, wired end to end for the ngarvey user: the
# package, its settings.json, its hosted-LLM credentials and the model list for
# the self-hosted inference servers: wabbajack's llama.cpp on every workstation,
# plus the local ninfer server on a host that runs one.
#
# Wired in via modules/desktop/common-workstation.nix, so every workstation gets
# it. The only per-host knob is homelab.pi.ninfer.enable. The home-manager NixOS
# module this depends on arrives from modules/home/ngarvey.nix, imported
# alongside this one there.
#
# Three things about pi.nix (the upstream flake) that shape what this module can
# do, all from its coding-agent/options.nix:
#   - It installs pi by wrapping the binary in a shell script that carries the
#     settings, models and environment. Config and package therefore cannot be
#     split, which is why pi comes from home-manager rather than
#     environment.systemPackages like every other workstation program.
#   - `settings` is jq-merged into the existing settings.json on every launch
#     rather than symlinked, so pi's own writes to that file (lastChangelogVersion,
#     an in-app theme switch) survive. The keys set below are put back each launch.
#   - `models` is installed only when ~/.pi/agent/models.json does not exist; it
#     never overwrites one. After editing configs/pi/models.json, delete that file
#     to pick the change up.
#
# The hosted-provider API keys in secrets/llm-api-keys.yaml are the only
# credentials managed here: DeepSeek, Fireworks and OpenAI, all of which pi has
# a built-in provider and model catalog for, so the key in the environment is
# all they need. pi's other providers live in ~/.pi/agent/auth.json, which pi
# owns and nix does not touch.

let
  cfg = config.homelab.pi;

  # configs/pi/models.json lists every self-hosted provider; ninfer is dropped
  # on hosts that do not run it.
  models = lib.importJSON ../../configs/pi/models.json;
  hostModels = models // {
    providers = lib.filterAttrs (name: _: name != "ninfer" || cfg.ninfer.enable) models.providers;
  };
in
{
  options.homelab.pi = {
    enable = lib.mkEnableOption "the pi coding agent for the ngarvey user";

    ninfer.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this host runs the local ninfer inference server that the
        `ninfer` provider in configs/pi/models.json points at
        (http://127.0.0.1:8080/v1). When true the provider is included in the
        installed models.json, so it can be picked from pi's model list; when
        false it is left out rather than offering a model that can never
        answer. Either way the default model stays DeepSeek Flash.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # pi reads its env file as the ngarvey user, so the secrets must be owned by
    # it.
    sops.secrets.deepseek-api-key = {
      sopsFile = ../../secrets/llm-api-keys.yaml;
      owner = "ngarvey";
    };

    sops.secrets.fireworks-api-key = {
      sopsFile = ../../secrets/llm-api-keys.yaml;
      owner = "ngarvey";
    };

    sops.secrets.openai-api-key = {
      sopsFile = ../../secrets/llm-api-keys.yaml;
      owner = "ngarvey";
    };

    home-manager.sharedModules = [ inputs.pi-nix.homeModules.default ];

    home-manager.users.ngarvey.programs.pi.coding-agent = {
      enable = true;

      environment.DEEPSEEK_API_KEY.file = config.sops.secrets.deepseek-api-key.path;
      environment.FIREWORKS_API_KEY.file = config.sops.secrets.fireworks-api-key.path;
      environment.OPENAI_API_KEY.file = config.sops.secrets.openai-api-key.path;

      models = pkgs.writeText "pi-models.json" (builtins.toJSON hostModels);

      settings = {
        theme = "dark";
        defaultThinkingLevel = "medium";
        defaultProvider = "deepseek";
        defaultModel = "deepseek-v4-flash";
      };
    };
  };
}
