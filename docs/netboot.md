# Netbooting the live environment

Any machine on the LAN can PXE-boot the same rescue/install system the
`live-iso` ISO carries, with no USB stick. `lydia` serves it.

## Booting a machine

1. In the machine's firmware, enable network/PXE boot and put it first in the
   boot order (on the Beelink/Topton N150 boxes this is *Advanced → Network
   Stack → IPv4 PXE Support*).
2. Boot. The machine takes a normal DHCP lease from the router, then picks up
   the boot answer from lydia, chainloads iPXE, and pulls the kernel and initrd
   over HTTP.
3. It lands at a root shell — passwordless on the console, and reachable over
   SSH with the usual key. `disko`, `parted`, `btrfs-progs`, `cryptsetup` and
   `smartmontools` are on PATH.

Watch it from lydia:

```sh
journalctl -u pixiecore -f
curl -s localhost:8880/_/booting     # 200 once the server is up
```

## How it is wired

| Piece | Where |
|---|---|
| Live system, medium-independent | `hosts/live-iso/common.nix` |
| ISO flavour | `hosts/live-iso/configuration.nix` → flake output `live-iso` |
| Netboot flavour | `hosts/live-iso/netboot.nix` → flake output `live-netboot` |
| Boot server | `modules/services/netboot-server.nix`, imported by `hosts/lydia` |

The server is [pixiecore](https://github.com/danderson/netboot) in `boot` mode:
it is handed the `live-netboot` kernel, initrd and kernel command line by store
path and serves TFTP (iPXE binaries) plus HTTP (kernel/initrd) itself. Ports
67/4011 udp, 69 udp and 8880 tcp are opened on lydia via `openFirewall`.

### Why pixiecore on lydia and not `BootFilename=` on the router

The router's DHCP server is systemd-networkd (`modules/router/dhcp.nix`), which
has a single `BootFilename=` and no way to select a boot file per client
architecture — BIOS and UEFI clients need different iPXE binaries. pixiecore
answers as **proxyDHCP**: it supplies boot information only and never hands out
addresses, so it coexists with networkd on a different host entirely, and the
static-lease table that also feeds DNS stays untouched. lydia is always on and
sits on the same flat `10.28.0.0/16` broadcast domain, which is all proxyDHCP
needs.

## Gotcha: the live system is in lydia's closure

`mode = "boot"` references the live kernel, initrd and toplevel by store path,
so they are part of lydia's system closure. **A change under `hosts/live-iso/`
is not served until lydia is rebuilt and redeployed:**

```sh
nix develop -c deploy --hosts lydia
```

Confirm the new paths took effect with `systemctl cat pixiecore | grep ExecStart`.
