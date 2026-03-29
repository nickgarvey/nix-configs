# Canonical source of static LAN host assignments.
# Consumed by: kea DHCP (reservations), blocky DNS (local records), k3s-hosts (extraHosts).
{
  lanHosts = [
    { hostname = "homeassistant"; mac = "f4:4d:30:6e:98:42"; ipv4 = "10.28.1.100"; }
    { hostname = "wireless";      mac = "fc:34:97:8f:1c:e0"; ipv4 = "10.28.1.2"; }
    { hostname = "lg-device";     mac = "28:0f:eb:91:76:fa"; ipv4 = "10.28.1.8"; }
    { hostname = "camera";        mac = "c4:3c:b0:f9:df:19"; ipv4 = "10.28.4.2"; }
    { hostname = "desktop-nixos"; mac = "bc:fc:e7:1c:40:0f"; ipv4 = "10.28.8.80"; }
    { hostname = "glkvm";         mac = "94:83:c4:bb:1c:0d"; ipv4 = "10.28.9.145"; }
    { hostname = "truenas";       mac = "bc:24:11:60:4d:67"; ipv4 = "10.28.12.16"; }
    { hostname = "k3s-node-1";    mac = "78:55:36:00:4c:c4"; ipv4 = "10.28.15.1"; }
    { hostname = "k3s-node-2";    mac = "78:55:36:00:47:f2"; ipv4 = "10.28.15.2"; }
    { hostname = "k3s-node-3";    mac = "78:55:36:00:4d:80"; ipv4 = "10.28.15.3"; }
    { hostname = "framework";     mac = "9c:bf:0d:01:0e:95"; ipv4 = "10.28.15.4"; }
    { hostname = "minicheese";    mac = "a8:a1:59:d9:d2:3b"; ipv4 = "10.28.12.108"; }
    { hostname = "unifi";         mac = "";                  ipv4 = "10.28.15.203"; }
    { hostname = "trmnl-display"; mac = "";                  ipv4 = "10.28.15.210"; }
  ];
}
