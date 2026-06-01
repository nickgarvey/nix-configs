# deployment

Go rewrite of the NixOS deploy orchestrator. Replaces `scripts/deploy.py`.

## What it does

Deploys NixOS configs to managed hosts using a watchdog-protected flow:
build on `talos`, pre-copy the closure to the target, arm a
`systemd-run` reboot timer, activate via `switch-to-configuration test`,
verify connectivity + system path, persist via `switch-to-configuration boot`,
disarm. If anything between arm and disarm fails (network breakage,
mis-activation, mid-deploy reboot), the watchdog reboots the target to its
previous boot generation.

The closure transfer and `nix eval` happen **before** the watchdog is armed,
so the at-risk window contains only fast SSH RPCs.

## Quick start

The flake's devShell builds the binary and puts `deploy` on your PATH:

```sh
nix develop -c deploy --hosts ro
nix develop -c deploy                              # all default hosts
nix develop -c deploy --hosts router,talos
```

Or inside the devshell:

```sh
nix develop
deploy --hosts ro
```

Outside the devshell:

```sh
nix run .#deploy -- --hosts ro
```

## Flags

| Flag | Values | Default | Notes |
|---|---|---|---|
| `--hosts` | comma list | (all default hosts) | Named hosts deploy even if `Default=false` (e.g. `framework13-laptop`). |
| `--mode` | `safe` \| `switch` \| `boot` | `safe` | See modes below. |
| `--reboot` | `auto` \| `never` \| `always` \| `ask` | `auto` | See reboot table below. |

### Modes

- **`safe`** — full watchdog flow. Use this unless you have a reason not to.
- **`switch`** — `nixos-rebuild switch`, no watchdog. Debug only.
- **`boot`** — `nixos-rebuild boot`. Persists the new generation without
  activating it. Use for changes that require a reboot to take effect
  (e.g. dbus implementation switch). The flow assumes a reboot is needed
  and acts according to `--reboot`.

### Reboot decision

|              | NEVER host    | PROMPT host        | AUTO host         |
|--------------|---------------|--------------------|-------------------|
| `auto`       | skip (warn)   | prompt iff changed | reboot iff changed|
| `never`      | skip          | skip               | skip              |
| `always`     | skip (warn)   | reboot             | reboot            |
| `ask`        | skip          | prompt             | prompt            |

`NEVER` (router) is hard policy and never reboots regardless of `--reboot`.

"Changed" = the running kernel version differs from
`/run/current-system/kernel-modules/...`, or `/run/booted-system/kernel-params`
differs (as a set) from `/run/current-system/kernel-params`.

## Per-host policy

Source of truth: `hosts.go` `AllHosts`. Summary:

| Host | Order | Reboot | k8s health | Default | Notes |
|---|---|---|---|---|---|
| fus / ro / dah | 10–12 | auto | ✓ | ✓ | IPv6 gateway ping |
| framework-desktop | 20 | prompt | – | ✓ | |
| talos | 21 | prompt | – | ✓ | also the build host |
| lydia | 30 | prompt | – | ✓ | |
| framework13-laptop | 40 | prompt | – | opt-in | only deploys when named explicitly |
| skyforge | 50 | prompt | – | ✓ | aarch64; built via talos binfmt |
| router | 99 | **never** | – | ✓ | extended connectivity (IPv6 tunnel, DNS, internet) |

## Safe deploy flow

```
1. Build on talos + copy closure to target   ─┐ pre-watchdog
2. Stop stale deploy-watchdog-* + nixos-rebuild   │ (slow OK)
   units from prior runs                          ─┘
3. Arm watchdog (systemd-run, 2 min)              ─┐
4. switch-to-configuration test                    │
5. Verify connectivity (per-host checks, 3 retries)│ at-risk window
6. Verify /run/current-system == built path        │ (only fast SSH RPCs)
7. Persist: nix-env --set + switch-to-config boot  │
8. Disarm watchdog                                ─┘

9. Reboot if needed (per the decision table above) + k8s health (if applicable)
```

### When the watchdog fires

The target reboots to its previous boot generation. The script reports
failure and exits the host (continuing with the rest unless it's a k3s
node — k3s failures hard-stop the remaining k3s rollout for cluster
stability).

### Why we don't use `nixos-rebuild test` / `nixos-rebuild boot` under the watchdog

`nixos-rebuild` re-evals on talos and re-checks the closure on every
invocation. The build at step 1 already populated the target's nix store
(via `--target-host` + `--use-substitutes`), so we can call
`switch-to-configuration` directly on the known store path. This keeps the
watchdog window to seconds.

## Tests / development

```sh
nix develop -c go test ./deployment/...
nix develop -c go vet  ./deployment/...
nix flake check                                   # runs the same go test
```

All command invocations go through a `Runner` interface so the deploy state
machine is tested with a `FakeRunner` — no real ssh required.

## Migration from `scripts/deploy.py`

| Old | New |
|---|---|
| (default) | `--mode safe` (default) |
| `--no-safe` | `--mode switch` |
| `--boot-only` | `--mode boot` |
| `--reboot` | `--reboot always` |
| `--no-reboot` | `--reboot never` |
| `--force-reboot` | `--reboot ask` is the closest; or `--reboot always` |
| `--hosts a b c` (space) | `--hosts a,b,c` (comma) |
| `--group k3s` | `--hosts fus,ro,dah` |
| `--dry-run` | (removed; run `nix flake check` + `nix build` manually) |
| `--skip-flake-check` | (removed; flake check no longer run by deploy) |
| `--skip-k8s-check` | (removed; always runs) |
| `--no-build-host` | (removed; talos is always the build host) |
| `--watchdog-timeout`, `--deploy-timeout` | (removed; hardcoded in `deploy.go`) |
