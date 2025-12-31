{ config, lib, pkgs, ... }:

{
  networking.extraHosts = ''
    10.28.15.1 k3s-node-1 k3s-node-1.home.arpa
    10.28.15.2 k3s-node-2 k3s-node-2.home.arpa
    10.28.15.3 k3s-node-3 k3s-node-3.home.arpa
    10.28.15.4 framework framework.home.arpa
  '';
}

