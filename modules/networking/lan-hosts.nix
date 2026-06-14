# Canonical source of static LAN host assignments (physical hosts with MACs).
# Consumed by: kea DHCP (reservations), blocky DNS (A/AAAA records),
# networkd.nix (static IPv6), k3s-common.nix (node-ip).
#
# Non-host DNS (service aliases, VIPs, CNAMEs) lives in dns.nix.
#
# Most IPv6 addresses are from the main LAN subnet 2001:470:482f::/64.
# Some hosts also own a dedicated per-host /64 carved from the HE /48 (for
# their nspawn containers / k3s pods). Those hosts keep their own identity
# here in the main LAN /64 and carry the delegated /64's gateway on their
# bridge separately (homelab.network.bridge.ipv6.extraAddresses / podCIDR).
# Subnet plan inside 2001:470:482f::/48:
#   :0::/64       main LAN (most hosts SLAAC + static here)
#   :2::/64       k8s LB pool (Cilium L2 announce)
#   :100::/56     k3s pod CIDRs (/64 per node)
#   :200::/56     per-host delegations (one /64 per host)
{
  lanHosts = [
    { hostname = "talos";         mac = "34:5a:60:b6:5f:90"; ipv4 = "10.28.8.80";    ipv6 = "2001:470:482f::5"; }       # garage container /64: 2001:470:482f:201::/64 (gw ::201::1 on vmbr0)
    { hostname = "lydia";         mac = "9c:6b:00:af:e9:d0"; ipv4 = "10.28.12.108";  ipv6 = "2001:470:482f::6"; }       # garage container /64: 2001:470:482f:200::/64 (gw ::200::1 on vmbr0)
    { hostname = "homeassistant"; mac = "f4:4d:30:6e:98:42"; ipv4 = "10.28.1.100";   ipv6 = "2001:470:482f:0:ddc2:6cba:8b8e:69a6"; }
    { hostname = "lg-device";     mac = "28:0f:eb:91:76:fa"; ipv4 = "10.28.1.8";     ipv6 = null; }
    { hostname = "skyforge";      mac = "2c:cf:67:0c:3c:08"; ipv4 = "10.28.1.4";     ipv6 = "2001:470:482f::4"; }
    { hostname = "camera";        mac = "c4:3c:b0:f9:df:19"; ipv4 = "10.28.4.2";     ipv6 = null; }
    { hostname = "glkvm";         mac = "94:83:c4:bb:1c:0d"; ipv4 = "10.28.9.145";   ipv6 = null; }
    { hostname = "fus";           mac = "78:55:36:00:4c:c4"; ipv4 = "10.28.15.1";    ipv6 = "2001:470:482f::21"; podCIDR = "2001:470:482f:100::/64"; }
    { hostname = "ro";            mac = "78:55:36:00:47:f2"; ipv4 = "10.28.15.2";    ipv6 = "2001:470:482f::22"; podCIDR = "2001:470:482f:104::/64"; }
    { hostname = "dah";           mac = "78:55:36:00:4d:80"; ipv4 = "10.28.15.3";    ipv6 = "2001:470:482f::23"; podCIDR = "2001:470:482f:103::/64"; }
  ];
}
