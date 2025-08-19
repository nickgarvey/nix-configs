#!/bin/bash
set -ex

nixos-rebuild switch --target-host k3s-node-1.home.arpa --flake .#k3s-node-1 --no-reexec --build-host k3s-node-1.home.arpa  --sudo
nixos-rebuild switch --target-host k3s-node-2.home.arpa --flake .#k3s-node-2 --no-reexec --build-host k3s-node-2.home.arpa  --sudo
nixos-rebuild switch --target-host k3s-node-3.home.arpa --flake .#k3s-node-3 --no-reexec --build-host k3s-node-3.home.arpa  --sudo
