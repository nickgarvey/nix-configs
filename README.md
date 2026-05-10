# Nick's Nix

This is a mono-repo for all my nix settings. Here are the sections:

* `hosts/`: NixOS configurations for each machine
* `lib/`: Helper functions
* `modules/`: Reusable NixOS modules (e.g. nixos-common is applied to all hosts)
* `pkgs/`: Custom packages for things not in nixpkgs
* `scripts/`: Deployment automation (`deploy.py`)

## Architecture

### Kubernetes

`k3-lion`, `k3s-dragon` and `k3s-goat` are the three heads of the [chimera](https://www.aidedd.org/dnd/monstres.php?vo=chimera) which is the Kubernetes cluster.

[`modules/k3s-common.nix`](modules/k3s-common.nix) contain the main configuration for those hosts.

Services running on that cluster are found in the [k8s-gitops](https://github.com/nickgarvey/k8s-gitops) repository.

### Desktops Become Servers

`tarrasque` is truly [a monster](https://www.aidedd.org/dnd/monstres.php?vo=tarrasque) with a 9950x3d and RTX 5090. This runs LLMs, performs Nix builds for other hosts, and serves the Nix cache.

`aboleth` has 128GB of DDR4 ECC RAM, so it acts as a storage and VM server to [hoard its memories](https://www.aidedd.org/dnd/monstres.php?vo=aboleth).

`framework-desktop` is a 128GB model of the Framework Desktop. LLM performance was underwhelming, so it largely acts as a surprisingly quiet TV computer.

## Hardware

| Host | Machine | CPU | RAM | GPU | Primary storage |
|------|---------|-----|-----|-----|-----------------|
| [`router`](hosts/router) | Topton Fanless PC| Intel N150 | 16 GB | iGPU (Alder Lake-N) | Samsung 870 QVO 1 TB SATA |
| [`k3s-lion`](hosts/k3s-lion) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`k3s-dragon`](hosts/k3s-dragon) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`k3s-goat`](hosts/k3s-goat) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`aboleth`](hosts/aboleth) | ASRock Industrial IMB-X1314 | Intel i5-12600K | 128 GB | iGPU (UHD 770) | Samsung 980 Pro 2 TB NVMe + 2× Seagate 8 TB HDD |
| [`tarrasque`](hosts/tarrasque) | ASUS PRIME X870-P WIFI | AMD Ryzen 9 9950X3D | 64 GB | NVIDIA RTX 5090 | WD_BLACK SN850X 2 TB NVMe |
| [`framework-desktop`](hosts/framework-desktop) | Framework Desktop | AMD Ryzen AI Max+ 395 (Strix Halo) | 128 GB | Radeon 8060S iGPU | WD_BLACK SN7100 2 TB NVMe |
| [`framework13-laptop`](hosts/framework13-laptop) | Framework Laptop 13 | AMD Ryzen AI 7 350 | 64 GB | Radeon 860M iGPU | KIOXIA 2 TB NVMe |
