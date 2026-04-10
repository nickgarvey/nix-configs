# Canonical source of static LAN host assignments.
# Consumed by: kea DHCP (reservations), blocky DNS (local records), k3s-hosts (extraHosts), network.nix (static IPv6).
#
# IPv6 addresses are from 2001:470:482f::/64 (HE /48 subnet :0).
# Subnet plan: :0 = main LAN, :1 = (reserved), :2 = k8s services (MetalLB), :3+ = future VLANs
{
  # DNS-only aliases (no DHCP reservation — point to an existing host's IP)
  dnsAliases = [
    { hostname = "router";   ipv4 = "10.28.0.1";      ipv6 = "2001:470:482f::1"; }
    { hostname = "frigate";  ipv4 = "10.28.12.109";    ipv6 = null; }
    { hostname = "smb";      ipv4 = "10.28.12.110";    ipv6 = null; }
    { hostname = "k3s-api";  ipv4 = null;              ipv6 = "2001:470:482f::21"; }
    # plex, unifi, trmnl-display: DNS handled by CNAME → k8s-gateway (see blocky-dns.nix)
  ];

  lanHosts = [
    { hostname = "desktop-nixos"; mac = "bc:fc:e7:1c:40:0f"; ipv4 = "10.28.8.80";    ipv6 = "2001:470:482f::10"; }
    { hostname = "microatx";      mac = "9c:6b:00:af:e9:d0"; ipv4 = "10.28.12.108";  ipv6 = "2001:470:482f::11"; }
    { hostname = "homeassistant"; mac = "f4:4d:30:6e:98:42"; ipv4 = "10.28.1.100";   ipv6 = null; }
    { hostname = "lg-device";     mac = "28:0f:eb:91:76:fa"; ipv4 = "10.28.1.8";     ipv6 = null; }
    { hostname = "camera";        mac = "c4:3c:b0:f9:df:19"; ipv4 = "10.28.4.2";     ipv6 = null; }
    { hostname = "glkvm";         mac = "94:83:c4:bb:1c:0d"; ipv4 = "10.28.9.145";   ipv6 = null; }
    { hostname = "k3s-node-1";    mac = "78:55:36:00:4c:c4"; ipv4 = "10.28.15.1";    ipv6 = "2001:470:482f::21"; }
    { hostname = "k3s-node-2";    mac = "78:55:36:00:47:f2"; ipv4 = "10.28.15.2";    ipv6 = "2001:470:482f::22"; }
    { hostname = "k3s-node-3";    mac = "78:55:36:00:4d:80"; ipv4 = "10.28.15.3";    ipv6 = "2001:470:482f::23"; }
    { hostname = "framework";     mac = "9c:bf:0d:01:0e:95"; ipv4 = "10.28.15.4";    ipv6 = "2001:470:482f::12"; }
    { hostname = "k3s-vm-node-1";   mac = "02:00:00:00:01:20"; ipv4 = "10.28.15.5";    ipv6 = "2001:470:482f::13"; }
    { hostname = "k3s-vm-server-1"; mac = "02:00:00:00:02:01"; ipv4 = "10.28.15.11";   ipv6 = "2001:470:482f::31"; }
    { hostname = "k3s-vm-server-2"; mac = "02:00:00:00:02:02"; ipv4 = "10.28.15.12";   ipv6 = "2001:470:482f::32"; }
    { hostname = "k3s-vm-server-3"; mac = "02:00:00:00:02:03"; ipv4 = "10.28.15.13";   ipv6 = "2001:470:482f::33"; }
  ];
}
