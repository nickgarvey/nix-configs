# Canonical source of static LAN host assignments.
# Consumed by: kea DHCP (reservations), blocky DNS (local records), k3s-hosts (extraHosts).
{
  lanHosts = [
    { hostname = "k3s-node-1";    mac = "78:55:36:00:4c:c4"; ipv4 = "10.28.15.1"; }
    { hostname = "k3s-node-2";    mac = "78:55:36:00:47:f2"; ipv4 = "10.28.15.2"; }
    { hostname = "k3s-node-3";    mac = "78:55:36:00:4d:80"; ipv4 = "10.28.15.3"; }
    { hostname = "framework";     mac = "9c:bf:0d:01:0e:95"; ipv4 = "10.28.15.4"; }
    { hostname = "truenas";       mac = "bc:24:11:60:4d:67"; ipv4 = "10.28.12.16"; }
    { hostname = "desktop-nixos"; mac = "bc:fc:e7:1c:40:0f"; ipv4 = "10.28.12.10"; }
    # Add more hosts as needed
  ];
}
