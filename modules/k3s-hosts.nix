{ config, lib, pkgs, ... }:

let
  inherit (import ./lan-hosts.nix) lanHosts dnsAliases;
  allHosts = lanHosts ++ dnsAliases;
  domain = "home.arpa";
in
{
  networking.extraHosts =
    let
      ipv4Lines = map (h: "${h.ipv4} ${h.hostname} ${h.hostname}.${domain}")
        (builtins.filter (h: h.ipv4 != null) allHosts);
      ipv6Lines = map (h: "${h.ipv6} ${h.hostname} ${h.hostname}.${domain}")
        (builtins.filter (h: h.ipv6 != null) allHosts);
    in
    lib.concatStringsSep "\n" (ipv4Lines ++ ipv6Lines);
}
