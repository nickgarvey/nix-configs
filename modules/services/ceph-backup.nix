# Daily Kopia backups of every Ceph RBD volume in the `kubernetes` pool to Garage, plus the `ceph-restore` helper.
#
# Runs on one storage node. For each image ceph-csi created: snapshot it
# (crash-consistent), clone the snapshot and mount the clone, so ext4 replays
# its journal and the files are consistent, then `kopia snapshot create` the
# mount. The Kopia repository is the `ceph-backup` bucket on Garage, encrypted
# with the password in secrets/ceph-backup.yaml. Recovery: docs/ceph-backup.md.
{ config, lib, pkgs, ... }:

let
  ceph = config.services.ceph.mon.package;
  pool = "kubernetes";
  # Namespaces whose volumes are not backed up. Only for data that is
  # reproducible or held elsewhere; every other PVC is backed up.
  # mimir: its volume is ingester WAL and cache; the long-term blocks are in
  # Storj.
  excludeNamespaces = [ "mimir" ];

  # Days of daily backups kept per namespace, where it differs from the
  # default 14. prometheus: local retention is 7 days and everything is also
  # remote-written to Mimir, so older backups add space on Garage but no data.
  keepDays = { prometheus = 7; };

  stateDir = "/var/lib/ceph-backup";

  # Shared by the backup job and ceph-restore: environment, repository
  # connection, and the lock that keeps them from running at once.
  common = ''
    # Not every script uses every variable.
    # shellcheck disable=SC2034
    POOL=${pool}
    # Snapshots and clones this tool makes. A leftover one stops ceph-csi from
    # deleting its image, so everything with this prefix is cleaned up on sight.
    # shellcheck disable=SC2034
    PREFIX=kopia-backup
    STATE=${stateDir}
    export KOPIA_CONFIG_PATH=$STATE/repository.config
    export KOPIA_CACHE_DIRECTORY=/var/cache/ceph-backup
    export KOPIA_LOG_DIR=/var/log/ceph-backup
    export KOPIA_CHECK_FOR_UPDATES=false
    # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (Garage) and KOPIA_PASSWORD.
    set -a
    # shellcheck disable=SC1091
    . ${config.sops.templates."ceph-backup.env".path}
    set +a

    exec 9>/run/lock/ceph-backup.lock
    flock -n 9 || { echo "ceph-backup or ceph-restore is already running" >&2; exit 1; }

    connect() {
      kopia repository status >/dev/null 2>&1 && return 0
      # The hostname/username overrides make snapshot sources independent of
      # which node takes them, so history survives moving the job.
      kopia repository connect s3 --bucket=ceph-backup \
        --endpoint=garage.home.garvey.sh --region=garage \
        --override-hostname=ceph-backup --override-username=root
    }

    image_meta() { rbd image-meta get "$POOL/$1" "csi.storage.k8s.io/pvc/$2" 2>/dev/null; }
  '';

  runtimeInputs = [ ceph pkgs.kopia pkgs.jq pkgs.util-linux pkgs.e2fsprogs pkgs.findutils pkgs.coreutils pkgs.gnugrep ];

  backup = pkgs.writeShellApplication {
    name = "ceph-backup";
    inherit runtimeInputs;
    text = common + ''
      MNT=/run/ceph-backup
      mkdir -p "$STATE/status"

      failed=0
      # Written even when the run dies part-way, so the alert sees a failure
      # rather than a stale success.
      trap 'rc=$?; [ $rc -ne 0 ] && failed=1; echo "$((1 - failed)) $(date +%s)" > "$STATE/last-run"' EXIT

      cleanup() {
        # Finding nothing is normal (findmnt and grep then exit 1); failing to
        # remove something is not, and fails the run so the alert fires.
        local dev m clone img s
        for dev in $(rbd device list --format json |
            jq -r --arg p "$PREFIX-" '.[] | select(.name | startswith($p)) | .device'); do
          for m in $(findmnt -rn -S "$dev" -o TARGET || true); do umount "$m"; done
          rbd device unmap "$dev"
        done
        for clone in $(rbd ls "$POOL" | grep "^$PREFIX-" || true); do
          rbd rm --no-progress "$POOL/$clone"
        done
        for img in $(rbd ls "$POOL" | grep -v "^$PREFIX-" || true); do
          for s in $(rbd snap ls --format json "$POOL/$img" |
              jq -r --arg p "$PREFIX-" '.[] | select(.name | startswith($p)) | .name'); do
            rbd snap unprotect "$POOL/$img@$s" 2>/dev/null || true
            rbd snap rm --no-progress "$POOL/$img@$s"
          done
        done
      }

      backup_one() {
        img=$1
        if ! ns=$(image_meta "$img" namespace) || ! pvc=$(image_meta "$img" name); then
          echo "$img: no PVC metadata, skipping"
          return 0
        fi
        excluded=(${lib.escapeShellArgs excludeNamespaces})
        for x in "''${excluded[@]}"; do
          [ "$ns" = "$x" ] && { echo "$ns/$pvc: namespace excluded"; return 0; }
        done
        snap="$PREFIX-$(date -u +%Y%m%dT%H%M%SZ)"
        clone="$PREFIX-$img"
        rbd snap create "$POOL/$img@$snap"
        rbd snap protect "$POOL/$img@$snap"
        rbd clone "$POOL/$img@$snap" "$POOL/$clone"
        dev=$(rbd device map "$POOL/$clone")
        if blkid -p "$dev" >/dev/null 2>&1; then
          mnt="$MNT/$ns/$pvc"
          mkdir -p "$mnt"
          mount -o noatime "$dev" "$mnt"
          kopia snapshot create "$mnt" \
            --tags "namespace:$ns" --tags "pvc:$pvc" --tags "image:$img"
          umount "$mnt"
          echo "$ns $pvc $(date +%s)" > "$STATE/status/$img"
        else
          # ceph-csi formats a volume the first time it is mounted.
          echo "$ns/$pvc: no filesystem yet, skipping"
        fi
        rbd device unmap "$dev"
        rbd rm --no-progress "$POOL/$clone"
        rbd snap unprotect "$POOL/$img@$snap"
        rbd snap rm --no-progress "$POOL/$img@$snap"
      }

      cleanup
      connect
      kopia policy set --global --compression=zstd-fastest \
        --keep-latest=14 --keep-daily=14 --keep-hourly=0 \
        --keep-weekly=0 --keep-monthly=0 --keep-annual=0
      # Policies on a path apply to every volume mounted beneath it.
      ${lib.concatStrings (lib.mapAttrsToList (ns: days: ''
        kopia policy set "root@ceph-backup:/run/ceph-backup/${ns}" --keep-latest=${toString days} --keep-daily=${toString days}
      '') keepDays)}
      mapfile -t images < <(rbd ls "$POOL" | grep -v "^$PREFIX-" || true)
      for img in "''${images[@]}"; do
        set +e
        (set -e; backup_one "$img")
        rc=$?
        set -e
        if [ $rc -ne 0 ]; then
          echo "$img: backup FAILED" >&2
          failed=1
          cleanup
        fi
      done

      # Forget volumes that no longer exist, so their last success does not
      # go stale and alert forever.
      for f in "$STATE"/status/*; do
        [ -e "$f" ] || continue
        img=$(basename "$f")
        printf '%s\n' "''${images[@]}" | grep -qx "$img" || rm -f "$f"
      done

      exit $failed
    '';
  };

  restore = pkgs.writeShellApplication {
    name = "ceph-restore";
    inherit runtimeInputs;
    text = ''
      image=""
      if [ "''${1:-}" = --image ]; then image=''${2:-}; shift 2; fi
      if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        echo "usage: ceph-restore [--image <rbd-image>] <namespace> <pvc> [kopia-snapshot-id]" >&2
        echo "Replaces the PVC's contents with the snapshot (default: latest)." >&2
        echo "Scale the app to 0 first; list snapshots with:" >&2
        echo "  sudo ceph-restore-kopia snapshot list --all --tags pvc:<pvc>" >&2
        exit 2
      fi
      ns=$1; pvc=$2; snapid=''${3:-}
    '' + common + ''
      find_images() {
        rbd ls "$POOL" | grep -v "^$PREFIX-" | while read -r img; do
          [ "$(image_meta "$img" namespace || true)" = "$ns" ] &&
            [ "$(image_meta "$img" name || true)" = "$pvc" ] && echo "$img"
        done
      }
      if [ -n "$image" ]; then
        img=$image
      else
        # A re-created PVC's old image lingers for a few seconds while ceph-csi
        # deletes it, so give it time to go before calling this ambiguous.
        for _ in $(seq 12); do
          mapfile -t matches < <(find_images)
          [ "''${#matches[@]}" -eq 1 ] && break
          sleep 5
        done
        if [ "''${#matches[@]}" -ne 1 ]; then
          echo "expected one image for $ns/$pvc in pool $POOL, found ''${#matches[@]}:" >&2
          for m in "''${matches[@]}"; do
            echo "  $m (PV $(rbd image-meta get "$POOL/$m" csi.storage.k8s.io/pv/name 2>/dev/null || echo unknown))" >&2
          done
          echo "If the PVC was deleted, re-apply it from k8s-gitops first. To choose, pass" >&2
          echo "--image for the PV named by: kubectl -n $ns get pvc $pvc -o jsonpath='{.spec.volumeName}'" >&2
          exit 1
        fi
        img=''${matches[0]}
      fi
      if [ "$(rbd status --format json "$POOL/$img" | jq '.watchers | length')" -ne 0 ]; then
        echo "$ns/$pvc ($img) is in use; scale its app to 0 first" >&2
        exit 1
      fi

      connect
      if [ -z "$snapid" ]; then
        snapid=$(kopia snapshot list --all --json |
          jq -r --arg ns "$ns" --arg pvc "$pvc" \
            '[.[] | select(.tags["tag:namespace"] == $ns and .tags["tag:pvc"] == $pvc)]
             | sort_by(.startTime) | last | .id // empty')
        [ -n "$snapid" ] || { echo "no backups of $ns/$pvc" >&2; exit 1; }
      fi
      echo "restoring $ns/$pvc ($img) from snapshot $snapid"

      mnt=/run/ceph-restore/$ns/$pvc
      dev=$(rbd device map "$POOL/$img")
      trap 'umount "$mnt" 2>/dev/null || true; rbd device unmap "$dev" || true' EXIT
      # A PVC that has never been mounted has no filesystem yet; ceph-csi
      # keeps an existing ext4 as it is. ceph-csi runs resize2fs from its own
      # e2fsprogs 1.46 on every mount, which refuses the features newer
      # mkfs.ext4 turns on by default, so leave those off.
      blkid -p "$dev" >/dev/null 2>&1 ||
        mkfs.ext4 -q -O ^orphan_file,^metadata_csum_seed "$dev"
      mkdir -p "$mnt"
      mount "$dev" "$mnt"
      find "$mnt" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      kopia snapshot restore "$snapid" "$mnt"
      echo "done; scale the app back up"
    '';
  };

  # Plain kopia against the backup repository, for listing and file-level
  # restores (docs/ceph-backup.md).
  kopiaWrapper = pkgs.writeShellApplication {
    name = "ceph-restore-kopia";
    inherit runtimeInputs;
    text = common + ''
      connect
      exec kopia "$@"
    '';
  };
in
{
  sops.secrets.ceph-backup-key-id = { sopsFile = ../../secrets/ceph-backup.yaml; key = "garage_key_id"; };
  sops.secrets.ceph-backup-secret-key = { sopsFile = ../../secrets/ceph-backup.yaml; key = "garage_secret_key"; };
  sops.secrets.ceph-backup-kopia-password = { sopsFile = ../../secrets/ceph-backup.yaml; key = "kopia_password"; };
  sops.templates."ceph-backup.env".content = ''
    AWS_ACCESS_KEY_ID=${config.sops.placeholder.ceph-backup-key-id}
    AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.ceph-backup-secret-key}
    KOPIA_PASSWORD=${config.sops.placeholder.ceph-backup-kopia-password}
  '';

  # Plain kopia too, for the by-hand steps in docs/ceph-backup.md.
  environment.systemPackages = [ restore kopiaWrapper pkgs.kopia ];

  systemd.services.ceph-backup = {
    description = "Kopia backup of every Ceph RBD volume to Garage";
    after = [ "network-online.target" "ceph.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backup;
      StateDirectory = "ceph-backup";
      # vector (below) reads the status files.
      StateDirectoryMode = "0755";
      CacheDirectory = "ceph-backup";
      LogsDirectory = "ceph-backup";
    };
  };

  systemd.timers.ceph-backup = {
    wantedBy = [ "timers.target" ];
    # An hour after Longhorn's own daily backup (09:00 UTC), while both exist.
    timerConfig = {
      OnCalendar = "*-*-* 10:00:00 UTC";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # Pushed rather than scraped (modules/services/vector-agent.nix). Every 180s,
  # under Prometheus's 5-minute staleness window, so the series do not blink
  # out between pushes. Alerts: k8s-gitops manifests/prometheus/rules/ceph-backup.yaml.
  homelab.metrics.sources.ceph_backup_volumes = {
    type = "exec";
    mode = "scheduled";
    scheduled.exec_interval_secs = 180;
    command = [ "${pkgs.bash}/bin/bash" "-c" "cat ${stateDir}/status/* 2>/dev/null || true" ];
  };
  homelab.metrics.transforms.ceph_backup_volumes_fields = {
    type = "remap";
    inputs = [ "ceph_backup_volumes" ];
    source = ''
      parts = split(strip_whitespace!(to_string!(.message)), " ")
      .namespace = parts[0]
      .pvc = parts[1]
      .value = to_int!(parts[2])
    '';
  };
  homelab.metrics.transforms.ceph_backup_volumes_metric = {
    type = "log_to_metric";
    inputs = [ "ceph_backup_volumes_fields" ];
    metrics = [{
      type = "gauge";
      field = "value";
      name = "homelab_ceph_backup_last_success_timestamp_seconds";
      tags = {
        namespace = "{{ namespace }}";
        pvc = "{{ pvc }}";
        hostname = config.networking.hostName;
      };
    }];
  };

  homelab.metrics.sources.ceph_backup_run = {
    type = "exec";
    mode = "scheduled";
    scheduled.exec_interval_secs = 180;
    command = [ "${pkgs.bash}/bin/bash" "-c" "cat ${stateDir}/last-run 2>/dev/null || true" ];
  };
  homelab.metrics.transforms.ceph_backup_run_fields = {
    type = "remap";
    inputs = [ "ceph_backup_run" ];
    source = ''
      parts = split(strip_whitespace!(to_string!(.message)), " ")
      .ok = to_int!(parts[0])
      .at = to_int!(parts[1])
    '';
  };
  homelab.metrics.transforms.ceph_backup_run_metric = {
    type = "log_to_metric";
    inputs = [ "ceph_backup_run_fields" ];
    metrics = [
      {
        type = "gauge";
        field = "ok";
        name = "homelab_ceph_backup_last_run_success";
        tags.hostname = config.networking.hostName;
      }
      {
        type = "gauge";
        field = "at";
        name = "homelab_ceph_backup_last_run_timestamp_seconds";
        tags.hostname = config.networking.hostName;
      }
    ];
  };
}
