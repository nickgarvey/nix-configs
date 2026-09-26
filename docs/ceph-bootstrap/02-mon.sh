# Run on each node, as root, after /root/ceph-bootstrap holds ceph.mon.keyring,
# ceph.client.admin.keyring and monmap. Initialises and starts this node's mon.
set -euo pipefail
H=$(hostname); B=/root/ceph-bootstrap
install -m 600 $B/ceph.client.admin.keyring /etc/ceph/ceph.client.admin.keyring
install -o ceph -g ceph -m 600 $B/ceph.mon.keyring $B/monmap /run/ceph/
install -d -o ceph -g ceph /var/lib/ceph/mon/ceph-$H
sudo -u ceph ceph-mon --mkfs -i $H --monmap /run/ceph/monmap --keyring /run/ceph/ceph.mon.keyring
rm /run/ceph/ceph.mon.keyring /run/ceph/monmap
sudo -u ceph touch /var/lib/ceph/mon/ceph-$H/done
systemctl start ceph-mon-$H
systemctl is-active ceph-mon-$H
