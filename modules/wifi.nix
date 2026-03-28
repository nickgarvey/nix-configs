{ config, lib, pkgs, ... }:

{
  sops.secrets.wifi-env = {
    sopsFile = ../secrets/wifi.yaml;
    key = "wifi_env";
  };

  networking.networkmanager.ensureProfiles = {
    environmentFiles = [ config.sops.secrets.wifi-env.path ];
    profiles.home-wifi = {
      connection = {
        id = "$WIFI_SSID";
        type = "wifi";
        autoconnect = true;
      };
      wifi = {
        ssid = "$WIFI_SSID";
        mode = "infrastructure";
      };
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$WIFI_PSK";
      };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };
  };
}
