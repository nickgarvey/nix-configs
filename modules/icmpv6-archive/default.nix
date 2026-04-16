{ config, lib, pkgs, ... }:

# ICMPv6 archive: rotating tcpdump → garage S3.
#
# There is no parsing, no enrichment, no realtime query path — pcap files on
# S3 are the system of record. Analyse on demand with `tshark -r` / `wireshark`.
#
# Strictly observational. Does not modify any network configuration.

let
  cfg = config.services.icmpv6-archive;

  # libpcap's `icmp6` only matches packets whose outer IPv6 next-header is 58.
  # MLD (types 130-132, 143) carries a Hop-by-Hop Router Alert option
  # (RFC 2710/3810), so the outer next-header is 0 and ICMPv6 lives after the
  # 8-byte HbH header. Without the second clause, the kernel BPF drops MLD
  # before tcpdump sees it.
  bpfFilter = "(icmp6 or (ip6[6] == 0 and ip6[40] == 58))";

  hostName = config.networking.hostName;

  uploadScript = pkgs.writeShellScript "icmpv6-archive-upload" ''
    set -uo pipefail

    # shellcheck disable=SC1090
    . "$S3_CREDENTIALS_FILE"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    export AWS_EC2_METADATA_DISABLED=true

    SPOOL="${cfg.spoolDir}"
    BUCKET="${cfg.s3.bucket}"
    ENDPOINT="${cfg.s3.endpoint}"
    HOST="${hostName}"

    AWS="${pkgs.awscli2}/bin/aws --endpoint-url=$ENDPOINT --region=${cfg.s3.region}"

    # Find the in-progress file (most recent mtime) and skip it. tcpdump's
    # -G rotation closes the previous file before opening the next, so any
    # *.pcap that isn't the newest is safe to upload.
    LATEST=$(${pkgs.coreutils}/bin/ls -1t "$SPOOL"/*.pcap 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)

    for f in "$SPOOL"/*.pcap; do
      [ -e "$f" ] || continue
      [ "$f" = "$LATEST" ] && continue

      base=$(${pkgs.coreutils}/bin/basename "$f")
      if $AWS s3 cp "$f" "s3://$BUCKET/$HOST/$base"; then
        ${pkgs.coreutils}/bin/mv "$f" "$f.uploaded"
      else
        echo "upload failed for $f, will retry next tick" >&2
      fi
    done

    ${pkgs.findutils}/bin/find "$SPOOL" -name '*.pcap.uploaded' \
      -mmin +${toString (cfg.localRetainHours * 60)} -delete
  '';

  hardenedServiceDefaults = {
    Restart = "on-failure";
    RestartSec = "30s";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    LockPersonality = true;
    RestrictRealtime = true;
    SystemCallArchitectures = "native";
  };
in
{
  options.services.icmpv6-archive = {
    enable = lib.mkEnableOption "ICMPv6 packet archive (tcpdump → garage S3)";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "any";
      description = ''
        Interface for tcpdump. "any" captures across all interfaces (incl.
        bridges and veths). Set to a specific name (e.g. "br-lan") to avoid
        the duplicate frames that "any" mode produces on bridged hosts.
      '';
    };

    snaplen = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      description = ''
        Bytes per packet to capture. 512 covers ICMPv6 + all standard ND
        options + link-layer addr with room to spare.
      '';
    };

    rotateSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "tcpdump -G: close the current pcap and open a new one every N seconds.";
    };

    spoolDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/icmpv6-pcap";
      description = "Local directory holding pcap files awaiting upload.";
    };

    localRetainHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = ''
        Keep already-uploaded pcap files locally for this many hours before
        deleting. Provides a window to inspect recent traffic without
        round-tripping S3.
      '';
    };

    s3 = {
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "http://[2001:470:482f::15]:3900";
        description = "S3 endpoint URL (garage).";
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        default = "icmpv6";
        description = "Destination bucket. Files land at s3://<bucket>/<host>/<file>.";
      };
      region = lib.mkOption {
        type = lib.types.str;
        default = "garage";
        description = "Region string. Garage ignores it but awscli requires one.";
      };
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file with two lines:
            AWS_ACCESS_KEY_ID=...
            AWS_SECRET_ACCESS_KEY=...
          Typically a sops template. Must be readable by root at runtime.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ tcpdump awscli2 ];

    systemd.tmpfiles.rules = [
      "d ${cfg.spoolDir} 0750 root root - -"
    ];

    systemd.services.icmpv6-archive-capture = {
      description = "icmpv6-archive: tcpdump rotating pcap capture";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 600;
      startLimitBurst = 3;
      environment.TZ = "UTC";
      serviceConfig = hardenedServiceDefaults // {
        Type = "simple";
        # -U flushes per packet so an unclean restart loses ≤1s of data.
        # %%Y%%m%%dT%%H%%M%%SZ — systemd specifier escape (%% → %), then tcpdump
        # expands strftime via localtime(3); TZ=UTC forces the "Z" suffix to be
        # truthful regardless of host timezone.
        ExecStart = lib.escapeShellArgs [
          "${pkgs.tcpdump}/bin/tcpdump"
          "-i" cfg.interface
          "-s" (toString cfg.snaplen)
          "-nn"
          "-p"
          "-U"
          "-G" (toString cfg.rotateSeconds)
          "-w" "${cfg.spoolDir}/${hostName}-%%Y%%m%%dT%%H%%M%%SZ.pcap"
          bpfFilter
        ];
        ReadWritePaths = [ cfg.spoolDir ];
        AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      };
    };

    systemd.services.icmpv6-archive-upload = {
      description = "icmpv6-archive: ship closed pcaps to garage S3";
      after = [ "network-online.target" "icmpv6-archive-capture.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [ "S3_CREDENTIALS_FILE=${cfg.s3.credentialsFile}" ];
        ExecStart = "${uploadScript}";
        ReadWritePaths = [ cfg.spoolDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    systemd.timers.icmpv6-archive-upload = {
      description = "icmpv6-archive: periodic upload tick";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "${toString cfg.rotateSeconds}s";
        AccuracySec = "5s";
      };
    };
  };
}
