{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkPackageOption
    mkOption
    literalExpression
    mkIf
    mkDefault
    types
    optionals
    getExe
    ;
  inherit (utils) escapeSystemdExecArgs;

  cfg = config.services.apollo;

  generatePorts = port: offsets: map (offset: port + offset) offsets;
  defaultPort = 47989;

  appsFormat = pkgs.formats.json { };
  settingsFormat = pkgs.formats.keyValue { };

  appsFile = appsFormat.generate "apps.json" cfg.applications;
  configFile = settingsFormat.generate "sunshine.conf" cfg.settings;
in
{
  options.services.apollo = with types; {
    enable = mkEnableOption "Apollo, a self-hosted game stream host for Artemis (Sunshine fork)";

    package = mkOption {
      type = types.package;
      default = pkgs.apollo or (throw "Apollo package not found. Ensure pkgs/apollo.nix is properly configured.");
      defaultText = literalExpression "pkgs.apollo";
      description = ''
        The Apollo package to use.
      '';
    };

    openFirewall = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to automatically open ports in the firewall.
      '';
    };

    capSysAdmin = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to give the Apollo binary CAP_SYS_ADMIN, required for DRM/KMS screen capture.
      '';
    };

    autoStart = mkOption {
      type = bool;
      default = true;
      description = ''
        Whether Apollo should be started automatically.
      '';
    };

    settings = mkOption {
      default = { };
      description = ''
        Settings to be rendered into the configuration file. If this is set, no configuration is possible from the web UI.

        See https://docs.lizardbyte.dev/projects/sunshine/en/latest/about/advanced_usage.html#configuration for syntax.
      '';
      example = literalExpression ''
        {
          sunshine_name = "nixos-apollo";
        }
      '';
      type = submodule (settings: {
        freeformType = settingsFormat.type;
        options.port = mkOption {
          type = port;
          default = defaultPort;
          description = ''
            Base port -- others used are offset from this one.
          '';
        };
      });
    };

    applications = mkOption {
      default = { };
      description = ''
        Configuration for applications to be exposed to Artemis/Moonlight. If this is set, no configuration is possible from the web UI.
      '';
      example = literalExpression ''
        {
          env = {
            PATH = "$(PATH):$(HOME)/.local/bin";
          };
          apps = [
            {
              name = "Desktop";
              prep-cmd = [
                {
                  do = "''${pkgs.libnotify}/bin/notify-send 'Starting stream'";
                  undo = "''${pkgs.libnotify}/bin/notify-send 'Stream ended'";
                }
              ];
            }
          ];
        }
      '';
      type = submodule {
        options = {
          env = mkOption {
            default = { };
            description = ''
              Environment variables to be set for the applications.
            '';
            type = attrsOf str;
          };
          apps = mkOption {
            default = [ ];
            description = ''
              Applications to be exposed to Artemis/Moonlight.
            '';
            type = listOf attrs;
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services.apollo.settings.file_apps = mkIf (cfg.applications.apps != [ ]) "${appsFile}";

    environment.systemPackages = [
      cfg.package
    ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = generatePorts cfg.settings.port [
        (-5) # HTTPS
        0 # HTTP
        1 # Control
        21 # Service Discovery
      ];
      allowedUDPPorts = generatePorts cfg.settings.port [
        9 # Audio
        10 # Video
        11 # Input
        13 # Discovery
        21 # Service Discovery
      ];
    };

    boot.kernelModules = [ "uinput" ];

    services.udev.packages = [ cfg.package ];

    services.avahi = {
      enable = mkDefault true;
      publish = {
        enable = mkDefault true;
        userServices = mkDefault true;
      };
    };

    security.wrappers.apollo = mkIf cfg.capSysAdmin {
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+p";
      source = getExe cfg.package;
    };

    systemd.user.services.apollo = {
      description = "Apollo - Self-hosted game stream host for Artemis";

      wantedBy = mkIf cfg.autoStart [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];

      startLimitIntervalSec = 500;
      startLimitBurst = 5;

      environment.PATH = lib.mkForce null;

      serviceConfig = {
        ExecStart = escapeSystemdExecArgs (
          [
            (if cfg.capSysAdmin then "${config.security.wrapperDir}/apollo" else "${getExe cfg.package}")
          ]
          ++ optionals (
            cfg.applications.apps != [ ]
            || (builtins.length (builtins.attrNames cfg.settings) > 1 || cfg.settings.port != defaultPort)
          ) [ "${configFile}" ]
        );
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
