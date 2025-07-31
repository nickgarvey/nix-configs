# Nick's Nix

This is a mono-repo for all my nix settings. Here are the sections:

* `hosts/`: nixos configurations, including desktop and k3s VMs
* `lib/`: Helper functions
* `modules/`: Modules intended to be included by other configurations, e.g. nixos-common is applied to all NixOS nodes.
* `overlays/`: Overlays used for package building
* `pkgs/`: Custom packages for things not in nixpkgs


Command references:
```
mkdir -p .extra-files/k3s/root/.config/sops/age
cp ~/.config/sops/age/k3s-keys.txt .extra-files/k3s/root/.config/sops/age

nix run github:nix-community/nixos-anywhere -- --flake ~/nixos-config#k3s-node-1 --generate-hardware-config nixos-generate-config hosts/k3s-node-1/hardware-configuration.nix --target-host root@10.28.9.174 --extra-files .extra-files/k3s

nixos-rebuild switch --target-host 10.28.9.175 --flake .#k3s-node-1 --fast --build-host 10.28.9.175  --use-remote-sudo
```
