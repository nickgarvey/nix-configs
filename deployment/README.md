# deployment

Go rewrite of the NixOS deploy orchestrator. Replaces `scripts/deploy.py`.

## What it does

Deploys NixOS configs to managed hosts. A precheck pass first resolves every
host's system path in one eval and probes all hosts concurrently (see below),
then each remaining host goes through a watchdog-protected flow: build locally,
pre-copy the closure to the target, arm a
`systemd-run` reboot timer, activate via `switch-to-configuration test`,
verify connectivity + system path, persist via `switch-to-configuration boot`,
disarm. If anything between arm and disarm fails (network breakage,
mis-activation, mid-deploy reboot), the watchdog reboots the target to its
previous boot generation.

The closure transfer happens **before** the watchdog is armed, so the at-risk
window contains only fast SSH RPCs. The path activated there is the one the
build reported, not the one the precheck resolved (see Precheck pass).

## Quick start

The flake's devShell builds the binary and puts `deploy` on your PATH:

```sh
nix develop -c deploy --hosts ro
nix develop -c deploy                              # all default hosts
nix develop -c deploy --hosts dragonsreach,talos
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
| `--hosts` | comma list | (all default hosts) | Named hosts deploy even if `Default=false` (e.g. `dovahkiin`). |
| `--mode` | `safe` \| `switch` \| `boot` | `safe` | See modes below. |
| `--reboot` | `never` \| `auto` \| `always` \| `ask` | `never` | See reboot table below. `--mode boot` accepts only `never` and `always`. |
| `--force` | flag | false | Skip safety pre-checks (e.g. active print on printer hosts). |

### Modes

- **`safe`** — full watchdog flow. Use this unless you have a reason not to.
- **`switch`** — `nixos-rebuild switch`, no watchdog. Debug only.
- **`boot`** — `nixos-rebuild boot`. Persists the new generation without
  activating it. Use for changes that require a reboot to take effect
  (e.g. dbus implementation switch). Nothing is activated, so there is nothing
  to compare against and **no reboot detection runs** — a reboot is owed by
  definition. `--reboot never` (default) stages and warns; `--reboot always`
  stages and reboots. `auto` and `ask` depend on detection and are rejected as a
  usage error.

### Reboot decision

`--reboot` is authoritative and applies uniformly to every host, including
`dragonsreach`. There is no per-host override.

| value | behavior |
|---|---|
| `never` (default) | never reboot; warn in the summary if a reboot is owed |
| `auto` | reboot iff changed, no prompt |
| `always` | reboot every selected host, changed or not |
| `ask` | prompt `[y/N]` iff changed; skip silently if not |

"Changed" is detected in `safe` and `switch` mode only; see `boot` above.

"Changed" = the running kernel version differs from
`/run/current-system/kernel-modules/...`, or `/run/booted-system/kernel-params`
differs (as a set) from `/run/current-system/kernel-params`.

## Per-host policy

Source of truth: `hosts.go` `AllHosts`. Summary:

| Host | Order | k8s health | Default | Notes |
|---|---|---|---|---|
| fus / ro / dah | 10–12 | ✓ | ✓ | SSH + IPv6 gateway ping |
| wabbajack | 20 | – | ✓ | SSH + gateway ping + IPv6 gateway ping |
| talos | 21 | – | ✓ | SSH + gateway ping |
| lydia | 30 | – | ✓ | SSH + gateway ping |
| dovahkiin | 40 | – | opt-in | only deploys when named explicitly |
| skyforge | 50 | – | ✓ | aarch64; needs binfmt on the deploying machine; printer idle pre-check |
| dragonsreach | 99 | – | ✓ | SSH + internet ping + DNS + IPv6 tunnel + IPv6 internet |

### Printer pre-check (skyforge)

During the precheck pass, any host in the `printer` group is queried via
moonraker to check if a print is active — before anything is built. If the
printer is busy, the host is **skipped** (not failed). Pass `--force` to
override and deploy regardless.

## Precheck pass

Before any host is touched, the run does two things for the whole fleet at once:

1. **Resolve** every selected host's system toplevel in a single `nix eval`.
   One process means nixpkgs is evaluated once for the fleet rather than once
   per host (~30s for nine hosts).
2. **Probe** all hosts concurrently: SSH reachability, moonraker print state for
   the `printer` group, and whether the host already runs *and* boots the
   resolved path.

The result is printed as a `Plan` block in host order (the probes are
concurrent; the reporting is not, so the output stays deterministic).

This decides three things before the first build runs:

- **Up to date** hosts skip build and copy entirely. They still go through the
  post-deploy path, because a host can be running the right config and still owe
  a reboot from an earlier one.
- **Mid-print** printer hosts are skipped without having built the most
  expensive closure in the fleet first. `--force` overrides.
- **Unreachable** hosts fail in seconds instead of after a multi-minute build.

A k3s node that fails the precheck aborts the whole run: the rolling deploy
takes one node down at a time assuming the other two are up, so rolling a second
with one already down would risk etcd quorum. This mirrors what a mid-deploy k3s
failure already does.

The precheck path decides *whether* a host needs a build; it is not what gets
activated. After the build, a single-host `nix eval` reports the path the build
actually produced, and that is what is activated and persisted. The two agree
whenever the flake source is unchanged between them — they disagree if the
working tree is dirty (`inputs.self.lastModified` is re-timed on every eval,
which reaches the closure of any host importing `modules/containers/knot-auth.nix`)
or if a commit lands mid-run. When they differ the run warns and continues with
the built path, since it is the one that exists on the target.

## Safe deploy flow

```
0. Precheck: resolve all paths (1 eval) + probe all hosts (concurrent)

1. Build locally + copy closure to target    ─┐ pre-watchdog
   (skipped entirely if the precheck said     │ (slow OK)
    the host is already up to date)           │
2. Stop stale deploy-watchdog-* + nixos-rebuild   │
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

`nixos-rebuild` re-evals and re-checks the closure on every
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
