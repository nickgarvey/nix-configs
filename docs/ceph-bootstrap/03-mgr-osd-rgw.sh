# Run on each node, as root, once the mons have quorum. Args: <osd id> <disk by-id path>.
# Creates this node's mgr, BlueStore OSD (whole raw disk) and RGW, and starts them.
set -euo pipefail
H=$(hostname); ID=$1; DISK=$2

d=/var/lib/ceph/mgr/ceph-$H; install -d -o ceph -g ceph $d
ceph auth get-or-create mgr.$H mon 'allow profile mgr' osd 'allow *' mds 'allow *' > $d/keyring
chown ceph:ceph $d/keyring; chmod 600 $d/keyring
systemctl start ceph-mgr-$H

d=/var/lib/ceph/osd/ceph-$ID; install -d -o ceph -g ceph $d
UUID=$(cat /proc/sys/kernel/random/uuid); KEY=$(ceph-authtool --gen-print-key)
echo bluestore > $d/type
ln -sfn "$DISK" $d/block
ceph-authtool --create-keyring $d/keyring --name osd.$ID --add-key "$KEY" >/dev/null
printf '{"cephx_secret": "%s"}' "$KEY" | ceph osd new $UUID $ID -i - >/dev/null
ceph-osd -i $ID --mkfs --osd-uuid $UUID
chown -R ceph:ceph $d
systemctl start ceph-osd-$ID

d=/var/lib/ceph/radosgw/ceph-rgw.$H; install -d -o ceph -g ceph $d
ceph auth get-or-create client.rgw.$H mon 'allow rw' osd 'allow rwx' mgr 'allow rw' > $d/keyring
chown ceph:ceph $d/keyring; chmod 600 $d/keyring
systemctl start ceph-rgw-rgw.$H
systemctl is-active ceph-mgr-$H ceph-osd-$ID ceph-rgw-rgw.$H | tr '\n' ' '
