# Run once, on any node, as root. Turns on the mgr prometheus module (port
# 9283), scraped by k8s-gitops manifests/prometheus/scrape-configs/ceph.yaml.
# Module state lives in the mon config database, not in NixOS.
set -euo pipefail
ceph mgr module enable prometheus
ceph mgr services
