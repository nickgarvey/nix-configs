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
* `configs/`: Standalone application config files
* `docs/`: Notes and troubleshooting docs

## Hardware

| Host | Machine | CPU | RAM | GPU | Primary storage |
|------|---------|-----|-----|-----|-----------------|
| [`talos`](hosts/talos) | MSI PRO X870E-P WIFI | AMD Ryzen 9 9950X3D | 64 GB | NVIDIA RTX 5090 | Kingston SNV2S 500 GB NVMe + Crucial T705 4 TB NVMe |
| [`lydia`](hosts/lydia) | ASRock Industrial IMB-X1314 | Intel i5-12600K | 128 GB | iGPU (UHD 770) | Samsung 980 Pro 2 TB NVMe + 2× WDC 6 TB HDD |
| [`fus`](hosts/fus) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`ro`](hosts/ro) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`dah`](hosts/dah) | Beelink EQ14 Mini PC | Intel N150 | 16 GB | iGPU (Alder Lake-N) | Crucial P3 500 GB NVMe |
| [`joor`](hosts/joor) | Beelink EQi Mini PC | Intel Core 3 304 (Wildcat Lake) | 32 GB | iGPU (Xe, Wildcat Lake) | YMTC 512 GB UFS + WD Blue SN5100 4 TB NVMe |
| [`zah`](hosts/zah) | Beelink EQi Mini PC | Intel Core 3 304 (Wildcat Lake) | 32 GB | iGPU (Xe, Wildcat Lake) | YMTC 512 GB UFS + WD Blue SN5100 4 TB NVMe |
| [`frul`](hosts/frul) | Beelink EQi Mini PC | Intel Core 3 304 (Wildcat Lake) | 32 GB | iGPU (Xe, Wildcat Lake) | YMTC 512 GB UFS + WD Blue SN5100 4 TB NVMe |
| [`wabbajack`](hosts/wabbajack) | Framework Desktop | AMD Ryzen AI Max+ 395 (Strix Halo) | 128 GB | Radeon 8060S iGPU | WD_BLACK SN850X 2 TB NVMe + WD_BLACK SN7100 2 TB NVMe |
| [`dovahkiin`](hosts/dovahkiin) | Framework Laptop 13 | AMD Ryzen AI 7 350 | 64 GB | Radeon 860M iGPU | KIOXIA 2 TB NVMe |
| [`guevenne`](hosts/guevenne) | ASUS Zenbook S 16 (UM5606WA) | AMD Ryzen AI 9 365 | 22 GB | Radeon 880M iGPU | Micron 2400 1 TB NVMe |
| [`dragonsreach`](hosts/dragonsreach) | Topton Fanless PC| Intel N150 | 16 GB | iGPU (Alder Lake-N) | Samsung 870 QVO 1 TB SATA |

### Kubernetes Hosts

`fus`, `ro` and `dah` are the control-plane nodes of the Kubernetes cluster.
`joor`, `zah` and `frul` join as workers (`services.k3s.role = "agent"`) and also
run the Ceph storage cluster on their 4 TB drives.

[`modules/k3s-common.nix`](modules/k3s-common.nix) contain the main configuration for those hosts.

Services running on that cluster are found in the [k8s-gitops](https://github.com/nickgarvey/k8s-gitops) repository.

### Servers

`lydia` has 128GB of DDR4 ECC RAM, so it acts as a storage/VM server.

`wabbajack` is the 128GB model of the Framework Desktop.

### Workstations
`talos` is the big desktop: 9950X3D and an RTX 5090, on a 500GB OS drive plus a 4TB btrfs carrying `/nix`, `/home` and `/var`.

`dovahkiin` is a AMD Ryzen AI 7 350 mainboard laptop with 64GB RAM I got off eBay. Eager to upgrade to a Panther Lake mainboard but going to wait for RAM to come down.

### Router
TopTon fanless PC with an Intel N150. 4x 2.5G NICs but I only use two of them (WAN/LAN).

## Installing a new host

Machines PXE-boot the live rescue/install environment off the LAN — `lydia`
serves it, no USB stick needed. See [`docs/netboot.md`](docs/netboot.md).

