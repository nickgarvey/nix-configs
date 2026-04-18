{ config, lib, pkgs, ... }:

let
  cfg = config.nspawn.frigate;
in
{
  options.nspawn.frigate = {
    localAddress = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 address with prefix length for the frigate container (e.g. \"10.28.12.109/16\" to match the flat LAN).";
    };

    localAddress6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "IPv6 address with prefix length for the frigate container.";
    };

    hostBridge = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge interface for the container network.";
    };

    dataPath = lib.mkOption {
      type = lib.types.str;
      description = "Host path for persistent frigate data.";
    };

    cachePath = lib.mkOption {
      type = lib.types.str;
      description = "Host path for frigate cache.";
    };
  };

  config = {
    # Coral Edge TPU (host loads modules for nspawn container)
    boot.extraModulePackages = with config.boot.kernelPackages; [ gasket ];
    boot.kernelModules = [ "apex" ];
    services.udev.extraRules = ''
      SUBSYSTEM=="apex", MODE="0660", GROUP="root"
    '';

    # RTSP credentials for cameras, rendered into an env file and bind-mounted
    # into the container so Frigate can substitute {FRIGATE_RTSP_USER} /
    # {FRIGATE_RTSP_PASSWORD} at config-load time.
    sops.secrets.frigate-rtsp-user = {
      sopsFile = ../../secrets/frigate.yaml;
      key = "frigate_rtsp_user";
    };
    sops.secrets.frigate-rtsp-password = {
      sopsFile = ../../secrets/frigate.yaml;
      key = "frigate_rtsp_password";
    };
    sops.templates."frigate-rtsp.env".content = ''
      FRIGATE_RTSP_USER=${config.sops.placeholder.frigate-rtsp-user}
      FRIGATE_RTSP_PASSWORD=${config.sops.placeholder.frigate-rtsp-password}
    '';

    # Tailscale auth key for first-boot login inside the container.
    sops.secrets.frigate-tailscale-authkey = {
      sopsFile = ../../secrets/frigate.yaml;
      key = "tailscale_auth_key";
    };

    containers.frigate = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.localAddress;
      localAddress6 = lib.mkIf (cfg.localAddress6 != null) cfg.localAddress6;

      bindMounts = {
        "/var/lib/frigate" = {
          hostPath = cfg.dataPath;
          isReadOnly = false;
        };
        "/var/cache/frigate" = {
          hostPath = cfg.cachePath;
          isReadOnly = false;
        };
        "/run/frigate-rtsp.env" = {
          hostPath = config.sops.templates."frigate-rtsp.env".path;
          isReadOnly = true;
        };
        "/run/tailscale-authkey" = {
          hostPath = config.sops.secrets.frigate-tailscale-authkey.path;
          isReadOnly = true;
        };
      };

      allowedDevices = [
        { node = "/dev/apex_0"; modifier = "rwm"; }
        { node = "/dev/net/tun"; modifier = "rwm"; }
      ];
      # NET_ADMIN is required for tailscaled to bring up the tun interface.
      additionalCapabilities = [ "CAP_NET_ADMIN" ];
      extraFlags = [ "--bind=/dev/apex_0" "--bind=/dev/net/tun" ];

      config = { config, pkgs, lib, ... }: let
        # Frigate's UI log tab reads /dev/shm/logs/<svc>/current, populated by
        # s6-log in the Docker image. NixOS has no s6, so mirror the journal.
        mkLogMirror = svc: {
          description = "Mirror ${svc} journal to /dev/shm/logs/${svc}/current";
          after = [ "${svc}.service" ];
          wantedBy = [ "${svc}.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.bash}/bin/bash -c 'exec ${pkgs.systemd}/bin/journalctl -u ${svc}.service -f -o cat -n 1000 > /dev/shm/logs/${svc}/current'";
            Restart = "always";
            RestartSec = "5";
          };
        };
      in {
        # Coral modules are loaded on the host; suppress inside container
        boot.extraModulePackages = lib.mkForce [];

        systemd.tmpfiles.rules = [
          "d /dev/shm/logs 0755 root root - -"
          "d /dev/shm/logs/frigate 0755 root root - -"
          "d /dev/shm/logs/go2rtc 0755 root root - -"
          "d /dev/shm/logs/nginx 0755 root root - -"
        ];

        systemd.services.frigate-log-mirror = mkLogMirror "frigate";
        systemd.services.go2rtc-log-mirror = mkLogMirror "go2rtc";
        systemd.services.nginx-log-mirror = mkLogMirror "nginx";

        # Fix /dev/apex_0 permissions (udev doesn't trigger for bind-mounted devices)
        systemd.services.frigate.serviceConfig.ExecStartPre = lib.mkBefore [
          "+${pkgs.coreutils}/bin/chown root:coral /dev/apex_0"
          "+${pkgs.coreutils}/bin/chmod 660 /dev/apex_0"
        ];

        # RTSP creds sourced from host-rendered sops template.
        systemd.services.frigate.serviceConfig.EnvironmentFile = "/run/frigate-rtsp.env";
        # NixOS splits frigate and go2rtc into separate services; go2rtc also
        # needs the RTSP creds to expand ${FRIGATE_RTSP_USER}/${FRIGATE_RTSP_PASSWORD}.
        systemd.services.go2rtc.serviceConfig.EnvironmentFile = "/run/frigate-rtsp.env";

        services.go2rtc = {
          enable = true;
          settings = {
            streams.camera = [
              "rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@camera.home.arpa:554/h264Preview_01_main"
            ];
            webrtc.candidates = [ "frigate.home.arpa:8555" ];
          };
        };

        services.frigate = {
          enable = true;
          hostname = "frigate";
          # Build-time config validator can't resolve {FRIGATE_RTSP_USER}/{FRIGATE_RTSP_PASSWORD}
          # placeholders that Frigate substitutes at runtime from the env file.
          checkConfig = false;
          settings = {
            mqtt.enabled = false;
            detectors.coral = {
              type = "edgetpu";
              device = "pci";
            };

            ffmpeg.output_args.record =
              "-f segment -segment_time 10 -segment_format mp4 "
              + "-reset_timestamps 1 -strftime 1 -c:v libx264 -an -crf 38";

            cameras.camera = {
              ffmpeg.inputs = [
                {
                  path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@camera.home.arpa:554/h264Preview_01_main";
                  roles = [ "record" ];
                }
                {
                  path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@camera.home.arpa:554/h264Preview_01_sub";
                  roles = [ "detect" ];
                }
              ];
              detect = {
                enabled = true;
                width = 640;
                height = 360;
              };
            };

            go2rtc = {
              streams.camera = [
                "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@camera.home.arpa:554/h264Preview_01_main"
              ];
              webrtc.candidates = [ "frigate.home.arpa:8555" ];
            };

            objects.track = [ "cat" ];

            record = {
              enabled = true;
              retain = {
                days = 7;
                mode = "motion";
              };
              alerts.retain.days = 200;
              detections.retain.days = 200;
            };
          };
        };

        networking = {
          defaultGateway = "10.28.0.1";
          nameservers = [ "10.28.0.1" ];
          useHostResolvConf = false;
          firewall.enable = false;
        };

        services.tailscale = {
          enable = true;
          authKeyFile = "/run/tailscale-authkey";
        };

        system.stateVersion = "25.05";
      };
    };
  };
}
