{ config, lib, pkgs, ... }:

# juicefs: a POSIX filesystem mounted from the garage S3 cluster.
#
# JuiceFS splits a filesystem in two: file *content* becomes content-addressed
# blocks in an S3 bucket, while all *metadata* (the tree, inodes, chunk maps)
# lives in a separate transactional store -- here a TiKV cluster in k3s, see
# k8s-gitops/manifests/juicefs/. The client talks to both directly, so both must
# be reachable from the workstation. Losing the metadata store makes every block
# in garage unaddressable even though the bytes are intact, which is why the
# mount runs `--backup-meta`: a periodic metadata dump lands in the bucket
# itself and is the actual disaster-recovery path.
#
# Blocks are uploaded concurrently, so write throughput is bounded by the link
# and by garage rather than by a single indexing thread.
#
# The volume root inode is owned by ngarvey, set once by hand after
# `juicefs format` (which leaves it root-owned). That ownership lives in the
# metadata engine, so it applies on every host that mounts the volume and needs
# no per-boot repair -- but reformatting the volume means redoing it.
#
# Lives in services/ rather than desktop/ because it is a network filesystem,
# not a desktop feature -- same reasoning as services/smb-automount.nix, which
# is likewise wired in from modules/desktop/common-workstation.nix.

let
  cfg = config.homelab.juicefs;
in
{
  options.homelab.juicefs = {
    enable = lib.mkEnableOption "the JuiceFS mount backed by garage S3 + TiKV metadata";

    metaUrl = lib.mkOption {
      type = lib.types.str;
      default = "tikv://[2001:470:482f:2::5005]:2379/jfs";
      description = ''
        Metadata engine URL. The host is PD's LoadBalancer address (pinned in
        k8s-gitops/manifests/juicefs/pd.yaml and published as juicefs-pd in
        modules/networking/dns.nix); the path segment is the key prefix inside
        TiKV, not a database name.

        The client contacts PD only to discover the TiKV stores, then dials each
        store directly at the pod IP PD advertises. That works because LAN hosts
        route to the pod CIDRs -- see modules/router/lan-ipv6.nix.

        Carries no credentials: PD and TiKV are unauthenticated on the LAN.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/home/ngarvey/local-drive";
      description = ''
        Where the filesystem is mounted. Created by the unit ExecStartPre,
        since FUSE will not mount onto a missing path.

        Living under /home means the unit needs RequiresMountsFor: /home is its
        own btrfs subvolume, and starting before it is mounted would put the
        drive on a directory that /home then hides.
      '';
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      default = "juicefs";
      description = "Garage bucket holding the data blocks.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://garage.home.garvey.sh";
      description = ''
        Garage S3 endpoint. Uses the TLS listener nginx terminates inside the
        garage container (docs/tls.md), not the plaintext :3900 -- that port
        stays up only as a degradation path for a failed certificate.

        The volume is formatted with `--storage s3`, not `--storage minio`:
        the minio backend pins the signing region to us-east-1, which garage
        rejects. Both speak path-style, so s3 is the one that works here.

        The hostname is load-bearing twice over: it is what the Let's Encrypt
        certificate attests, and it is what SigV4 signs. Never substitute one of
        the round-robin literals from the `garage` record in
        modules/networking/dns.nix.
      '';
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "garage";
      description = ''
        S3 region used to sign requests. Garage ignores the value itself but
        rejects a mismatch outright, with
        `AuthorizationHeaderMalformed: unexpected scope .../us-east-1/...`.

        This is NOT recorded in the volume settings at format time the way the
        bucket and access key are, so every client has to supply it or fail to
        sign -- which is why it is passed to the unit rather than left to the
        metadata engine.
      '';
    };

    cacheSize = lib.mkOption {
      type = lib.types.int;
      default = 10240;
      description = "Local block cache budget in MiB.";
    };

    metricsAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9567";
      description = "Prometheus endpoint the client exposes; juicefs-status scrapes it. Loopback only.";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      cacheDir = "/var/cache/juicefs";

      # FUSE will not mount onto a path that does not exist, and juicefs does not
      # create its mount point.
      #
      # 0555 root:root is the guard, not an oversight. While the drive is
      # mounted the mount's own root permissions apply and ngarvey has full
      # access; while it is NOT mounted this bare directory is what is exposed,
      # and read-only means a write fails with EACCES instead of quietly landing
      # on the local disk. That matters in a home directory, where files get
      # dropped in by a file manager rather than by someone who checked first.
      #
      # The unit is the only thing that creates this directory, deliberately.
      # A systemd.tmpfiles `d` rule would re-apply that mode on every
      # `systemd-tmpfiles --create` -- which a nixos-rebuild switch runs -- and
      # tmpfiles cannot tell a bare mount point from a live mount, so a switch
      # while mounted would stamp 0555 root:root onto the JuiceFS root itself
      # and persist it into the metadata engine.
      #
      # The mountpoint check is load-bearing for Restart=on-failure: a restart
      # that finds a stale FUSE mount still attached must not chmod the live
      # volume root, for exactly that reason.
      makeMountPoint = pkgs.writeShellScript "juicefs-make-mountpoint" ''
        ${pkgs.util-linux}/bin/mountpoint -q ${cfg.mountPoint} && exit 0
        ${pkgs.coreutils}/bin/mkdir -p ${cfg.mountPoint}
        ${pkgs.coreutils}/bin/chown root:root ${cfg.mountPoint}
        ${pkgs.coreutils}/bin/chmod 0555 ${cfg.mountPoint}
      '';

      # Reads the mount's own Prometheus endpoint: JuiceFS exposes no control
      # socket, so scraping /metrics is the only way to ask a running client
      # anything.
      #
      # The reportable states are deliberately few. Without --writeback (off, so
      # a crash cannot lose an un-uploaded write) writes are synchronous: there is
      # no background sync queue, and therefore no pending/committing phase to
      # show. What is knowable is whether the mount is alive, how fast bytes are
      # going out, and whether the object store is returning errors.
      juicefs-status = pkgs.writers.writePython3Bin "juicefs-status" { flakeIgnore = [ "E501" ]; } ''
        import json
        import os
        import sys
        import time
        import urllib.request

        METRICS = "http://${cfg.metricsAddr}/metrics"
        MOUNT = "${cfg.mountPoint}"

        # Cross-invocation scratch for the counter deltas. Waybar polls on an
        # interval and a counter alone says nothing about current rate.
        STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp",
                             "juicefs-status.state")

        # A delta measured across a longer gap than this says nothing useful.
        MAX_SAMPLE_AGE = 60.0


        def human(n):
            for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
                if abs(n) < 1024:
                    return "%.1f %s" % (n, unit)
                n /= 1024.0
            return "%.1f PiB" % n


        def compact(n):
            """Narrow form for the bar, so the module does not jitter mid-transfer."""
            for unit in ("B", "K", "M", "G", "T"):
                if abs(n) < 1024:
                    return "%.0f%s" % (n, unit) if unit == "B" else "%.1f%s" % (n, unit)
                n /= 1024.0
            return "%.1fP" % n


        def is_mounted():
            """/proc/mounts is authoritative; the metrics port can outlive a wedged mount."""
            try:
                with open("/proc/mounts") as f:
                    for line in f:
                        parts = line.split()
                        if len(parts) > 2 and parts[1] == MOUNT and parts[2].startswith("fuse"):
                            return True
            except OSError:
                pass
            return False


        def scrape():
            """Parse the text exposition into {name: {labelstring: value}}."""
            with urllib.request.urlopen(METRICS, timeout=2) as r:
                body = r.read().decode("utf-8", "replace")

            out = {}
            for line in body.splitlines():
                if not line or line.startswith("#"):
                    continue
                try:
                    key, value = line.rsplit(" ", 1)
                    value = float(value)
                except ValueError:
                    continue
                if "{" in key:
                    name, labels = key.split("{", 1)
                    labels = labels.rstrip("}")
                else:
                    name, labels = key, ""
                out.setdefault(name, {})[labels] = value
            return out


        def total(metrics, name, needle=None):
            """Sum a metric family, optionally only series whose labels contain needle."""
            series = metrics.get(name, {})
            return sum(v for k, v in series.items() if needle is None or needle in k)


        def read_state():
            try:
                with open(STATE) as f:
                    return json.load(f)
            except (OSError, ValueError):
                return {}


        def write_state(state):
            # Atomic: waybar polls on a timer and may race a hand-run invocation.
            tmp = "%s.%d" % (STATE, os.getpid())
            try:
                with open(tmp, "w") as f:
                    json.dump(state, f)
                os.replace(tmp, STATE)
            except OSError:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass


        def rate(state, key, value, now):
            """Per-second delta since the previous invocation, or None if unknowable.

            Returns None on a first sample, a stale one, or a counter reset (a
            remount), so the caller reports idle rather than inventing a spike.
            """
            prev = state.get(key)
            state[key] = {"v": value, "t": now}
            if not prev:
                return None
            elapsed = now - prev.get("t", 0)
            if elapsed <= 0 or elapsed > MAX_SAMPLE_AGE:
                return None
            delta = value - prev.get("v", 0)
            if delta < 0:
                return None
            return delta / elapsed


        def describe(info):
            lines = [
                "state:       %s" % info["state"],
                "mount:       %s" % MOUNT,
            ]
            if info.get("put_rate") is not None:
                lines.append("upload rate: %s/s" % human(info["put_rate"]))
            if info.get("used") is not None:
                lines.append("used:        %s" % human(info["used"]))
            if info.get("cache") is not None:
                lines.append("cache:       %s" % human(info["cache"]))
            if info.get("uptime") is not None:
                lines.append("uptime:      %s" % time.strftime("%H:%M:%S", time.gmtime(info["uptime"])))
            if info.get("errors"):
                lines += ["", "object store errors: %d total" % info["errors"]]
                if info.get("err_rate"):
                    lines.append("  %.2f/s right now" % info["err_rate"])
            return lines


        def offline(as_json, as_waybar, reason):
            # waybar must always get valid JSON and a zero exit: on anything else
            # it blanks the module, which is indistinguishable from "idle" -- the
            # exact case this indicator exists to catch.
            if as_waybar:
                print(json.dumps({"text": "JFS off", "class": "stopped",
                                  "tooltip": reason}))
                return 0
            if as_json:
                print(json.dumps({"state": "stopped", "error": reason}))
                return 0
            print(reason, file=sys.stderr)
            return 1


        def main():
            args = sys.argv[1:]
            as_json = "--json" in args
            as_waybar = "--waybar" in args

            if not is_mounted():
                return offline(as_json, as_waybar, "%s is not mounted" % MOUNT)

            try:
                metrics = scrape()
            except Exception as e:
                # Mounted but unreachable metrics means a wedged or starting
                # client, which is a real problem worth surfacing -- not idle.
                return offline(as_json, as_waybar, "cannot reach %s: %s" % (METRICS, e))

            now = time.time()
            state = read_state()

            put_bytes = total(metrics, "juicefs_object_request_data_bytes", 'method="PUT"')
            errors = total(metrics, "juicefs_object_request_errors")

            info = {
                "put_rate": rate(state, "put", put_bytes, now),
                "err_rate": rate(state, "err", errors, now),
                "errors": int(errors),
                "used": total(metrics, "juicefs_used_space") or None,
                "cache": total(metrics, "juicefs_blockcache_bytes") or None,
                "uptime": total(metrics, "juicefs_uptime") or None,
            }
            write_state(state)

            if info["err_rate"]:
                info["state"] = "error"
            elif info["put_rate"]:
                info["state"] = "uploading"
            else:
                info["state"] = "idle"

            if as_json:
                print(json.dumps(info))
                return 0

            if as_waybar:
                if info["state"] == "error":
                    text, cls = "JFS !%d" % info["errors"], "error"
                elif info["state"] == "uploading":
                    text, cls = "JFS %s/s" % compact(info["put_rate"]), "syncing"
                else:
                    text, cls = "JFS", "idle"
                print(json.dumps({"text": text, "class": cls,
                                  "tooltip": "\n".join(describe(info))}))
                return 0

            print("\n".join(describe(info)))
            return 2 if info["state"] == "error" else 0


        sys.exit(main())
      '';
    in
    {
      environment.systemPackages = [ pkgs.juicefs juicefs-status ];

      systemd.tmpfiles.rules = [
        "d ${cacheDir} 0700 root root -"
      ];

      sops.secrets.juicefs-s3-access-key = {
        sopsFile = ../../secrets/juicefs.yaml;
        key = "juicefs_s3_access_key";
      };
      sops.secrets.juicefs-s3-secret-key = {
        sopsFile = ../../secrets/juicefs.yaml;
        key = "juicefs_s3_secret_key";
      };

      # `juicefs format` persists these into the volume settings in TiKV, so a
      # mount can technically run without them. Passing them anyway keeps sops the
      # authoritative copy, so rotating the garage key is a redeploy rather than a
      # metadata edit. Root-owned (default 0400) because this is a system service.
      sops.templates."juicefs-s3.env".content = ''
        ACCESS_KEY=${config.sops.placeholder.juicefs-s3-access-key}
        SECRET_KEY=${config.sops.placeholder.juicefs-s3-secret-key}
      '';

      systemd.services.juicefs = {
        description = "JuiceFS mount (garage S3 + TiKV metadata)";
        # A system service rather than a user one: the mount is shared
        # infrastructure that should survive logout, and running as root lets the
        # credential stay 0400 root.
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # The mount point is inside /home, which is its own btrfs subvolume.
        # Without this the service can win the race at boot, mount onto the
        # directory of that name on the root filesystem, and then have /home
        # mount over the top -- leaving a drive that is running but invisible.
        unitConfig.RequiresMountsFor = [ (builtins.dirOf cfg.mountPoint) ];
        # juicefs execs fusermount3, and only the setuid wrapper can mount.
        path = [ "/run/wrappers" pkgs.fuse3 ];
        serviceConfig = {
          Type = "simple";
          EnvironmentFile = config.sops.templates."juicefs-s3.env".path;
          Environment = [
            "AWS_REGION=${cfg.region}"
            "AWS_DEFAULT_REGION=${cfg.region}"
          ];
          ExecStartPre = makeMountPoint;
          ExecStart = ''
            ${pkgs.juicefs}/bin/juicefs mount \
              --foreground \
              -o allow_other \
              --cache-dir ${cacheDir} \
              --cache-size ${toString cfg.cacheSize} \
              --backup-meta 1h \
              --metrics ${cfg.metricsAddr} \
              ${cfg.metaUrl} ${cfg.mountPoint}
          '';
          # A crash otherwise leaves a stale mount that blocks the next start.
          ExecStopPost = "-/run/wrappers/bin/fusermount3 -u ${cfg.mountPoint}";
          Restart = "on-failure";
          RestartSec = 10;
        };
      };
    }
  );
}
