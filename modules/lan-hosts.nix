# Canonical source of static LAN host assignments (physical hosts with MACs).
# Consumed by: kea DHCP (reservations), blocky DNS (A/AAAA records),
# lan-network.nix (static IPv6), k3s-common.nix (node-ip).
#
# Non-host DNS (service aliases, VIPs, CNAMEs) lives in dns.nix.
#
# IPv6 addresses are from 2001:470:482f::/64 (HE /48 subnet :0).
# Subnet plan: :0 = main LAN, :1 = (reserved), :2 = k8s LB (Cilium L2),
#   :100-:1ff = k8s pod CIDRs (/56, native routing, no masquerade), :3+ = future VLANs
{
  lanHosts = [
    { hostname = "tarrasque";     mac = "bc:fc:e7:1c:40:0f"; ipv4 = "10.28.8.80";    ipv6 = "2001:470:482f::10"; }
    { hostname = "microatx";      mac = "9c:6b:00:af:e9:d0"; ipv4 = "10.28.12.108";  ipv6 = "2001:470:482f::11"; }
    { hostname = "homeassistant"; mac = "f4:4d:30:6e:98:42"; ipv4 = "10.28.1.100";   ipv6 = "2001:470:482f:0:ddc2:6cba:8b8e:69a6"; }
    { hostname = "lg-device";     mac = "28:0f:eb:91:76:fa"; ipv4 = "10.28.1.8";     ipv6 = null; }
    { hostname = "camera";        mac = "c4:3c:b0:f9:df:19"; ipv4 = "10.28.4.2";     ipv6 = null; }
    { hostname = "glkvm";         mac = "94:83:c4:bb:1c:0d"; ipv4 = "10.28.9.145";   ipv6 = null; }
    { hostname = "k3s-node-1";    mac = "78:55:36:00:4c:c4"; ipv4 = "10.28.15.1";    ipv6 = "2001:470:482f::21"; podCIDR = "2001:470:482f:100::/64"; }
    { hostname = "k3s-node-2";    mac = "78:55:36:00:47:f2"; ipv4 = "10.28.15.2";    ipv6 = "2001:470:482f::22"; podCIDR = "2001:470:482f:101::/64"; }
    { hostname = "k3s-node-3";    mac = "78:55:36:00:4d:80"; ipv4 = "10.28.15.3";    ipv6 = "2001:470:482f::23"; podCIDR = "2001:470:482f:102::/64"; }
    { hostname = "framework-desktop";     mac = "9c:bf:0d:01:0e:95"; ipv4 = "10.28.15.4";    ipv6 = "2001:470:482f::12"; }
  ];
}
