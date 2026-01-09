{ config, lib, pkgs, ... }:

let
  uid = config.users.users.ngarvey.uid;
  gid = config.users.groups.users.gid;
  mountOptions = [
    "credentials=/run/secrets/rendered/smb-credentials"
    "uid=${toString uid}"
    "gid=${toString gid}"
    "iocharset=utf8"
    "file_mode=0664"
    "dir_mode=0775"
    "vers=3.0"
    "_netdev"
    "nodfs"
  ];
in
{
  environment.systemPackages = [ pkgs.cifs-utils ];
  boot.supportedFilesystems = [ "cifs" ];

  sops.secrets.smb-username = {
    sopsFile = ../secrets/smb-credentials.yaml;
    key = "smb_username";
  };

  sops.secrets.smb-password = {
    sopsFile = ../secrets/smb-credentials.yaml;
    key = "smb_password";
  };

  sops.templates."smb-credentials".content = ''
username=${config.sops.placeholder.smb-username}
password=${config.sops.placeholder.smb-password}
domain=WORKGROUP
'';

  systemd.tmpfiles.rules = [
    "d /shares/media 0755 root root -"
  ];

  systemd.mounts = [{
    what = "//truenas.home.arpa/media";
    where = "/shares/media";
    type = "cifs";
    options = lib.concatStringsSep "," (mountOptions ++ [ "ip=10.28.12.16" ]);
    wantedBy = [ ];
  }];

  systemd.automounts = [{
    where = "/shares/media";
    wantedBy = [ "multi-user.target" ];
    automountConfig = {
      TimeoutIdleSec = "600";
    };
  }];
}
