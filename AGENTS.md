# Nix Config Conventions

## Module taxonomy

Modules live under `modules/` grouped by concern. Add new modules to the
narrowest matching subdir; create a new one only when you have ≥2 related files.

| Subdir | What belongs here |
|---|---|
| `core/` | Baseline config applied to virtually every host (NixOS defaults, SSH, locale, CA certs). Currently: `nixos-common`, `nspawn-cleanup`. |
| `networking/` | Network configuration and shared host-address data. Currently: `networkd`, `network-manager`, `dns`, `lan-hosts`, `ipv6-accept-ra-routes`. |
| `desktop/` | Workstation/desktop features (Wayland compositors, audio, packages, udev rules for peripherals). Currently: `common-workstation`, `niri`, `steam`, `upower-overlay`, `opencloud-desktop`. |
| `nix/` | Nix-daemon tooling: binary caches, remote builders, flake checks. Currently: `nix-binary-cache`, `nix-remote-builder-client`, `flake-build-check`. |
| `services/` | Host services that don't fit a tighter category. Currently: `whisper-gpu`, `smb-automount`, `fancontrol`. |
| `k3s/` | Kubernetes cluster node configuration. Currently: `k3s-common`. |
| `router/` | Router subsystem (nftables, DHCP, DNS, IPv6 tunnel, NAT64). Exposes a `default.nix` — import the directory. |
| `containers/` | systemd-nspawn container definitions. Common networking lives in `common.nix`. |
| `microvm/` | MicroVM guest definitions. |
| `icmpv6-archive/` | ICMPv6 packet archiver service + SOPS secrets. Exposes a `default.nix` — import the directory. |

## Imports

Hosts import individual files by path:

```nix
imports = [
  ../../modules/core/nixos-common.nix
  ../../modules/networking/networkd.nix
  ../../modules/desktop/common-workstation.nix
];
```

No `default.nix` aggregators — except `router/` and `icmpv6-archive/`, which
intentionally expose one. Hosts opt in to each module explicitly.

## Host `configuration.nix` structure

```nix
imports = [
  ./hardware-configuration.nix          # hardware-config first
  # shared modules, grouped by subdir:
  ../../modules/core/nixos-common.nix
  ../../modules/networking/networkd.nix
  ../../modules/services/whisper-gpu.nix
  # host-specific opt-ins last
];
# host-specific config below the imports block
```

## Paths escaping `modules/`

When a module references `pkgs/`, `patches/`, `secrets/`, `configs/`, or
`public_certs/` it must use paths relative to its own location. From inside a
subdir (e.g. `modules/desktop/`) those roots are two levels up (`../../`), not
one. Example: `../../patches/my-fix.patch`.

## Module header comment

The first non-blank line of each module should be a `#` comment describing its
purpose in one sentence, so `ls` + skimming the top of a file is enough to
understand what it does.
