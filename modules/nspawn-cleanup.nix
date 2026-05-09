{ config, lib, pkgs, ... }:

# Workaround for systemd-nspawn leaking unix-export bind mounts on stop
# (https://github.com/systemd/systemd/issues/36455). When a container is
# restarted during nixos-rebuild activation, the leftover mount makes the
# next start fail with "Mount point ... exists already, refusing".
# `systemd-nspawn --cleanup` (added in systemd PR #34776) clears the leak.

{
  systemd.services = lib.mapAttrs'
    (name: _: lib.nameValuePair "container@${name}" {
      serviceConfig.ExecStartPre = [
        "${pkgs.systemd}/bin/systemd-nspawn --cleanup -D /var/lib/nixos-containers/%i"
      ];
    })
    config.containers;
}
