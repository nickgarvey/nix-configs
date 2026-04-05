# Nick's Nix

This is a mono-repo for all my nix settings. Here are the sections:

* `hosts/`: NixOS configurations for each machine
* `lib/`: Helper functions
* `modules/`: Reusable NixOS modules (e.g. nixos-common is applied to all hosts)
* `pkgs/`: Custom packages for things not in nixpkgs
* `scripts/`: Deployment automation (`deploy.py`)

Command references:
```
# Deploy to all hosts
./scripts/deploy.py

# Deploy to specific host
./scripts/deploy.py --hosts router

# Initial provisioning of a new k3s node
mkdir -p .extra-files/k3s/root/.config/sops/age
cp ~/.config/sops/age/k3s-keys.txt .extra-files/k3s/root/.config/sops/age

nix run github:nix-community/nixos-anywhere -- --flake ~/nix-configs#k3s-node-1 --generate-hardware-config nixos-generate-config hosts/k3s-node-1/hardware-configuration.nix --target-host root@10.28.9.174 --extra-files .extra-files/k3s
```
