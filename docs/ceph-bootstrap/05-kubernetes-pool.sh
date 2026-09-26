# Run once, on any node, as root. The RBD pool and client key for ceph-csi
# (k8s-gitops vendor/ceph-csi-rbd, manifests/ceph-csi-rbd), and PG sizing.
set -euo pipefail

# RGW creates its metadata pools with 32 PGs each, and the autoscaler keeps
# them there. Six of them used most of the 250-PGs-per-OSD budget
# (mon_max_pg_per_osd) and blocked the data pools from growing. They hold
# kilobytes, so pin them at 8.
for p in .rgw.root default.rgw.log default.rgw.control default.rgw.meta \
         default.rgw.buckets.index default.rgw.buckets.non-ec; do
  ceph osd pool set "$p" pg_autoscale_mode off
  ceph osd pool set "$p" pg_num 8
done

ceph osd pool create kubernetes
rbd pool init kubernetes
# Share of capacity the autoscaler plans PGs for.
ceph osd pool set kubernetes target_size_ratio 0.7
ceph osd pool set default.rgw.buckets.data target_size_ratio 0.3

# Key for ceph-csi, restricted to the kubernetes pool. Its secret is the
# SopsSecret in k8s-gitops manifests/ceph-csi-rbd/secret.yaml.
ceph auth get-or-create client.kubernetes \
  mon 'profile rbd' osd 'profile rbd pool=kubernetes' mgr 'profile rbd pool=kubernetes'
