# Ceph volume backups and recovery

Every volume ceph-csi creates in the `kubernetes` pool (StorageClass
`ceph-rbd`) is backed up daily by `ceph-backup.service` on joor
(`modules/services/ceph-backup.nix`), at 10:00 UTC, into a Kopia repository in
the `ceph-backup` bucket on Garage. Retention: the last 14 daily snapshots
(7 for `prometheus`). Not backed up: the `mimir` namespace, whose volume is
ingester WAL and cache (its long-term blocks are in Storj). Both are set at
the top of the module.

Each backup is crash-consistent: the image is snapshotted, the snapshot is
cloned and mounted (so ext4 replays its journal), and Kopia copies the files.
Kubernetes objects are not backed up; they are in k8s-gitops.

## What recovery needs

- The Kopia repository password and the Garage key: `secrets/ceph-backup.yaml`,
  decryptable by ngarvey and joor.
- Network access to `garage.home.garvey.sh`.
- `kopia`. joor has everything wired up (`ceph-restore`, `ceph-restore-kopia`);
  any other machine can connect by hand (below).

Nothing here depends on Ceph or Kubernetes still working.

## Look at the backups

On joor:

    sudo ceph-restore-kopia snapshot list --all --tags pvc:<pvc>
    sudo ceph-restore-kopia snapshot list --all          # every volume

`ceph-restore-kopia` is plain `kopia` already connected to the repository.
Snapshots are tagged `namespace:<ns>`, `pvc:<name>` and `image:<rbd image>`.

## 1. A few files back

The app can keep running.

    sudo ceph-restore-kopia snapshot restore <snapshot-id>/<path/in/volume> /tmp/restored
    # or browse a snapshot as a directory:
    sudo mkdir -p /tmp/snap && sudo ceph-restore-kopia mount <snapshot-id> /tmp/snap

Copy what you need into the app, e.g. with `kubectl cp`.

## 2. One volume back to a snapshot

For a corrupted volume, or one whose PVC was deleted (`ceph-rbd` deletes the
image with the PVC).

1. Scale the app to 0: nothing may have the volume mapped.
2. If the PVC is gone, re-apply it from k8s-gitops. ceph-csi creates a new,
   empty image.
3. On joor:

       sudo ceph-restore <namespace> <pvc> [snapshot-id]

   It finds the PVC's image, refuses if anything still uses it, formats it if
   it has never been mounted, empties it, and restores the snapshot (the latest
   if none is given). Right after a PVC is re-created, its old image lingers for
   a few seconds; the helper waits for it to go. If two images still match, it
   lists them with their PV names: pass `--image <rbd image>` for the PV in
   `kubectl -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}'`.
4. Scale the app back up and check it.

## 3. The whole Ceph cluster

1. Rebuild Ceph from `docs/ceph-bootstrap/` (01 to 05), on wiped mon/OSD
   state. 01 reuses the fsid in `modules/services/ceph.nix`, so ceph-csi's
   `clusterID` stays valid. 05 creates a new `client.kubernetes` key: re-encrypt
   it into k8s-gitops `manifests/ceph-csi-rbd/secret.yaml` and apply it. The
   admin key is new too; update `secrets/ceph-admin.yaml`.
2. Apply ceph-csi, then every app's PVCs with the apps scaled to 0.
3. `sudo ceph-restore <namespace> <pvc>` for each volume.
4. Start the apps; databases run their normal crash recovery.

Up to a day of data is lost (daily backups).

## From a machine other than joor

    export KOPIA_PASSWORD=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # from sops -d secrets/ceph-backup.yaml
    kopia repository connect s3 --bucket=ceph-backup \
      --endpoint=garage.home.garvey.sh --region=garage \
      --override-hostname=ceph-backup --override-username=root
    kopia snapshot list --all
    kopia snapshot restore <snapshot-id> <target-dir>

To restore into an RBD image by hand: `rbd device map kubernetes/<image>`,
mount it, empty it, `kopia snapshot restore` into it, unmount, unmap.

## Creating the repository (once)

Already done. For a new bucket:

    sudo sh -c 'set -a; . /run/secrets/rendered/ceph-backup.env; set +a;
      KOPIA_CONFIG_PATH=/var/lib/ceph-backup/repository.config \
      kopia repository create s3 --bucket=ceph-backup \
        --endpoint=garage.home.garvey.sh --region=garage \
        --override-hostname=ceph-backup --override-username=root'

## Alerts

vector on joor pushes `homelab_ceph_backup_last_success_timestamp_seconds`
(per namespace/pvc) and `homelab_ceph_backup_last_run_success`; rules in
k8s-gitops `manifests/prometheus/rules/ceph-backup.yaml`.
