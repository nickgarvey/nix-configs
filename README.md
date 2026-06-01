# Nick's Nix

This is a mono-repo for all my nix settings. Here are the sections:

* `hosts/`: NixOS configurations for each machine
* `lib/`: Helper functions
* `modules/`: Reusable NixOS modules (e.g. nixos-common is applied to all hosts)
* `pkgs/`: Custom packages for things not in nixpkgs
* `deployment/`: Go-based deployment tool (`deploy`)
* `devshells/`: Project-specific Nix dev shells
* `patches/`: Patches applied to upstream packages
* `secrets/`: SOPS-encrypted secrets
* `public_certs/`: Public CA certificates
* `configs/`: Standalone application config files
* `docs/`: Notes and troubleshooting docs

## Hardware

| Host | Machine | CPU | RAM | GPU | Primary storage |
|------|---------|-----|-----|-----|-----------------|
| [`talos`](hosts/talos) | ASUS PRIME X870-P WIFI | AMD Ryzen 9 9950X3D | 64 GB | NVIDIA RTX 5090 | WD_BLACK SN850X 2 TB NVMe |
| [`lydia`](hosts/lydia) | ASRock Industrial IMB-X1314 | Intel i5-12600K | 128 GB | iGPU (UHD 770) | Samsung 980 Pro 2 TB NVMe + 2× WDC 6 TB HDD |
| [`fus`](hosts/fus) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`ro`](hosts/ro) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`dah`](hosts/dah) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`wabbajack`](hosts/wabbajack) | Framework Desktop | AMD Ryzen AI Max+ 395 (Strix Halo) | 128 GB | Radeon 8060S iGPU | WD_BLACK SN7100 2 TB NVMe |
| [`dovahkiin`](hosts/dovahkiin) | Framework Laptop 13 | AMD Ryzen AI 7 350 | 64 GB | Radeon 860M iGPU | KIOXIA 2 TB NVMe |
| [`dragonsreach`](hosts/dragonsreach) | Topton Fanless PC| Intel N150 | 16 GB | iGPU (Alder Lake-N) | Samsung 870 QVO 1 TB SATA |

### Kubernetes Hosts

`fus`, `ro` and `dah` are the three nodes of the Kubernetes cluster.

[`modules/k3s-common.nix`](modules/k3s-common.nix) contain the main configuration for those hosts.

Services running on that cluster are found in the [k8s-gitops](https://github.com/nickgarvey/k8s-gitops) repository.

### Big Servers

`talos` has a 9950x3d and RTX 5090. This runs LLMs, performs Nix builds for other hosts, and serves the Nix cache.

`lydia` has 128GB of DDR4 ECC RAM, so it acts as a storage/VM server.

### Workstations
Workstations run COSMIC Desktop with a few patches (applied via [`modules/cosmic-comp-overlay.nix`](modules/cosmic-comp-overlay.nix)):
1. [Reduce animation time](patches/cosmic-comp-reduce-tiling-latency.patch) so everything feels snappier.
2. [Fix a suspend issue](patches/smithay-pending-blob-on-reset.patch). There is an upstream PR.

`wabbajack` is the 128GB model of the Framework Desktop. LLM performance was underwhelming, so it largely acts as a surprisingly quiet TV computer.

`dovahkiin` is a AMD Ryzen AI 7 350 mainboard laptop with 64GB RAM I got off eBay. Eager to upgrade to a Panther Lake mainboard but going to wait for RAM to come down.

### Router
TopTon fanless PC with an Intel N150. 4x 2.5G NICs but I only use two of them (WAN/LAN).

