# Run once, on joor, as root. Creates the cluster's initial keys and monmap in /root/ceph-bootstrap.
set -euo pipefail
FSID=8d324da3-f3ab-40f8-aaa1-71ed33705f75
B=/root/ceph-bootstrap; install -d -m 700 $B; cd $B
ceph-authtool --create-keyring ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'
ceph-authtool --create-keyring ceph.client.admin.keyring --gen-key -n client.admin \
  --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
ceph-authtool --create-keyring ceph.bootstrap-osd.keyring --gen-key -n client.bootstrap-osd \
  --cap mon 'profile bootstrap-osd' --cap mgr 'allow r'
ceph-authtool ceph.mon.keyring --import-keyring ceph.client.admin.keyring
ceph-authtool ceph.mon.keyring --import-keyring ceph.bootstrap-osd.keyring
monmaptool --create --fsid $FSID \
  --addv joor '[v2:[2001:470:482f::24]:3300,v1:[2001:470:482f::24]:6789]' \
  --addv zah  '[v2:[2001:470:482f::25]:3300,v1:[2001:470:482f::25]:6789]' \
  --addv frul '[v2:[2001:470:482f::26]:3300,v1:[2001:470:482f::26]:6789]' \
  monmap
monmaptool --print monmap
chmod 600 *
