{ config, lib, pkgs, ... }:

let
  inherit (import ./router/lan-hosts.nix) lanHosts;
  domain = "home.arpa";
in
{
  networking.extraHosts = lib.concatMapStringsSep "\n"
    (h: "${h.ipv4} ${h.hostname} ${h.hostname}.${domain}")
    lanHosts;
}
