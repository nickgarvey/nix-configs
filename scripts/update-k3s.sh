#!/bin/bash
set -ex

nixos-rebuild switch --target-host k3s-node-1.home.arpa --flake .#k3s-node-1 --fast --build-host k3s-node-1.home.arpa  --use-remote-sudo
nixos-rebuild switch --target-host k3s-node-2.home.arpa --flake .#k3s-node-2 --fast --build-host k3s-node-2.home.arpa  --use-remote-sudo
nixos-rebuild switch --target-host k3s-node-3.home.arpa --flake .#k3s-node-3 --fast --build-host k3s-node-3.home.arpa  --use-remote-sudo
