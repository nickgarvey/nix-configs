# deployment

Go rewrite of the NixOS deploy orchestrator. Replaces `scripts/deploy.py`.

## What it does

Deploys NixOS configs to managed hosts. A precheck pass first resolves every
host's derivation and system path in one eval and probes all hosts concurrently
(see below). The remaining hosts then move through a pipeline — build, copy,
activate — that overlaps across hosts while keeping activation to one host at a
time.

Each activation is watchdog-protected: arm a `systemd-run` reboot timer, activate
via `switch-to-configuration test`, verify connectivity + system path, persist via
`switch-to-configuration boot`, disarm. If anything between arm and disarm fails
(network breakage, mis-activation, mid-deploy reboot), the watchdog reboots the
target to its previous boot generation.

The closure transfer happens **before** the watchdog is armed, so the at-risk
window contains only fast SSH RPCs, and the path activated is pinned by the
derivation resolved in the precheck (see Precheck pass).

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
| `--on-failure` | `stop` \| `continue` | `stop` | What to do with the hosts still queued when one fails. A k3s failure always stops. |
| `--copy-jobs` | int | 4 | Concurrent closure copies. |
| `--max-jobs` | int | (nix.conf) | Passed to `nix build`. 0 leaves it to nix. |
| `--cores` | int | (nix.conf) | Passed to `nix build`. 0 leaves it to nix. |

### Modes

- **`safe`** — full watchdog flow. Use this unless you have a reason not to.
- **`switch`** — `nixos-rebuild switch`, no watchdog. Debug only. Not pipelined:
  nixos-rebuild does its own build and copy per host, so hosts run one at a time.
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

Source of truth: `hosts.go` `AllHosts`. `Order` no longer decides when a host is
deployed — in `safe` mode that is decided by readiness — it only orders this
table, the precheck report, and hosts that become ready in the same poll tick.
Summary:

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

The precheck resolves each host's *derivation* as well as its output path, and
the pipeline builds that derivation rather than the flake reference. Nothing
re-evaluates between the precheck and activation, so the path that is activated
is necessarily the one that was built.

That pinning is load-bearing, not an optimisation. `inputs.self.lastModified`
reaches the closure of every host importing `modules/containers/knot-auth.nix`
(the zone serial reads it) or `modules/desktop/mic-mute.nix`, so *any* change to
the source tree — a commit, or merely staging a file — moves those hosts' store
paths. A build that re-evaluated could produce a different path than the precheck
committed to, and the poller below would wait forever on one that never appears.

The same coupling blunts the up-to-date skip: after editing anything in the repo,
those hosts look stale even when nothing about them actually changed.

## Pipelined deploy

`--mode safe` overlaps the stages across hosts. A host copies as soon as its own
build lands and activates as soon as its own copy lands, without waiting for any
other host:

```
  ┌─ nix build  (ONE process, every changed host, --keep-going) ───────────┐
  │     poller: nix path-info per pending host, every 2s                   │
  └──────────┬─────────────────────────────────────────────────────────────┘
             │ this host's path is valid
             ▼
      copy workers (--copy-jobs, default 4)   nix copy --to ssh-ng://…
             │ this host's copy succeeded
             ▼
      activation worker (exactly ONE)         the safe flow below
```

Both queues are buffered to the host count, so no stage can block another.

**One `nix build` for the whole fleet** is what bounds this machine. A single nix
client is capped at nix's `max-jobs` no matter how many hosts are selected;
N concurrent `nixos-rebuild` processes would each get their own budget, so the
ceiling would be `max-jobs × N`. It also means derivations shared between hosts
are built once rather than once per host. `--max-jobs` and `--cores` are passed
through for when the machine is also in use.

`--keep-going` is why one host failing does not abort the others' builds; per-host
success is then decided by `nix path-info`, not by parsing the build log.

**Activation stays serial** — exactly one host is ever inside a watchdog window.
Everything that depended on that still holds for free: the k3s rolling gate
(`WaitForK8sReady` runs inside the activation, so the next node cannot start
until the previous one is Ready) and the `--reboot ask` prompt.

Ordering is otherwise first-ready-first-served rather than fixed by `Order`;
`Order` survives only as the tiebreak between hosts that become ready in the same
poll tick, which keeps runs reproducible. In particular **the router is no longer
deployed last**. Activating `dragonsreach` restarts its network, so a copy in
flight to another host can fail; that host is reported failed and re-running
redeploys only what did not land.

The closure transfer is `nix copy --to ssh-ng://<host> --substitute-on-destination
--no-check-sigs`, not `nixos-rebuild --target-host --sudo`. The remote nix-daemon
does the store write, so no sudo is involved.

`--no-check-sigs` is required, not an optimisation. Everything the pipeline
copies was just built locally and carries no signature, and `nix copy` asks the
destination to verify signatures by default — it does **not** relax that just
because the connection is trusted. Without the flag a transfer dies partway with
`cannot add path '...' because it lacks a signature by a trusted key`.

The flag is a request, not a bypass: the destination only honours it for a
connecting user in its `trusted-users`, which `modules/core/nixos-common.nix`
sets fleet-wide. Both halves are needed — `nix store info --store ssh-ng://<host>`
reporting `"trusted":true` only means the daemon *would permit* an unsigned add,
not that `nix copy` will request one.

## Safe deploy flow

Per host, once its closure is already on the target:

```
1. Stop stale deploy-watchdog-* + nixos-rebuild    (pre-watchdog)
   units from prior runs
2. Arm watchdog (systemd-run, 2 min)              ─┐
3. switch-to-configuration test                    │
4. Verify connectivity (per-host checks, 3 retries)│ at-risk window
5. Verify /run/current-system == built path        │ (only fast SSH RPCs)
6. Persist: nix-env --set + switch-to-config boot  │
7. Disarm watchdog                                ─┘

8. Reboot if needed (per the decision table above) + k8s health (if applicable)
```

A host the precheck found already up to date skips straight to step 8, since it
may still owe a reboot from an earlier run.

### When the watchdog fires

The target reboots to its previous boot generation. The run reports the host as
failed and moves on according to `--on-failure`; a k3s node always hard-stops the
remaining rollout, for cluster stability.

### Why we don't use `nixos-rebuild test` / `nixos-rebuild boot` under the watchdog

`nixos-rebuild` re-evals and re-checks the closure on every invocation. The
pipeline already populated the target's nix store with `nix copy`, so we can call
`switch-to-configuration` directly on the known store path. This keeps the
watchdog window to seconds — and the re-eval would also be free to produce a
different path than the one that was copied.

## Connection reuse

A safe deploy issues 15–25 remote commands per host. Each one used to be its own
`ssh` process, and so its own TCP + key exchange + auth handshake. The run now
opens **one ControlMaster per host** and every command rides it: `SSHControl`
(`ssh.go`) owns a socket directory under `/tmp` for the life of the process,
`ExecRunner` carries it, and `SSHArgv` splices in `ControlMaster=auto` +
`ControlPath` + `ControlPersist`. `nixos-rebuild`'s own ssh calls join the same
master via `NIX_SSHOPTS`.

The interesting part is what happens when a connection drops — which it does
routinely, since activation restarts networkd and reboots are a normal outcome.
Without a master, a drop costs nothing: the next command simply dials again.
With one, a drop leaves a socket that still *looks* alive, and a new session on
it ignores `ConnectTimeout` and blocks for ~45s. Left unhandled that turns a
healthy host into a failed connectivity check, and a failed connectivity check
reboots the box. Three things prevent it:

1. **Liveness probes never use the master.** The reboot wait, the
   post-activation probe, and the `ssh` connectivity check use `SSHRunDirect`
   (`ControlMaster=no`, `ControlPath=none`). Asking "is this host back?" is only
   meaningful over a fresh handshake.
2. **Everything else redials once.** `SSHRun` treats exit 255 or a timeout as a
   transport failure, discards the master and retries. Every command routed this
   way is idempotent. Arming the watchdog and activation use `SSHRunOnce`
   instead — the first must not run twice, the second does its own disconnect
   handling.
3. **The master is dropped where a drop is expected**: after activation
   (unconditionally — exiting 0 does not mean the connection survived), after
   issuing a reboot, between connectivity retries, and after `nixos-rebuild
   switch`.

`ControlPersist=300` is the backstop for anything that escapes: an orphaned
master reaps itself. Masters are closed per host as the run moves on, on normal
exit, and on SIGINT/SIGTERM.

Set `DEPLOY_NO_SSH_MUX=1` to turn all of this off; the argv is then identical to
the pre-multiplexing tool.

## Tests / development

```sh
nix develop -c go test ./deployment/...
nix develop -c go vet  ./deployment/...
nix flake check                                   # runs the same go test
```

All command invocations go through a `Runner` interface so the deploy state
machine is tested with a `FakeRunner` — no real ssh required.
