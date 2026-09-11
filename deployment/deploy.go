package main

import (
	"fmt"
	"strings"
	"time"
)

// Timeouts intentionally not exposed as CLI flags — tune here if needed.
const (
	watchdogTimeout = 120 * time.Second // systemd-run reboot timer
	deployTimeout   = 60 * time.Second  // per nixos-rebuild / activation call
	// activationTimeout is the per-call timeout for `switch-to-configuration
	// test|boot`. Generous to tolerate slow activation on weaker hosts.
	activationTimeout = 90 * time.Second
)

// Mode is the deploy mode (--mode).
type Mode string

const (
	ModeSafe   Mode = "safe"
	ModeSwitch Mode = "switch"
	ModeBoot   Mode = "boot"
)

func ParseMode(s string) (Mode, error) {
	switch Mode(s) {
	case ModeSafe, ModeSwitch, ModeBoot:
		return Mode(s), nil
	}
	return "", fmt.Errorf("invalid --mode value %q (want safe|switch|boot)", s)
}

// DeployContext bundles dependencies for one deploy operation. Carrying these
// in a struct instead of globals keeps tests hermetic.
type DeployContext struct {
	Runner     Runner
	Sleeper    func(time.Duration)
	Prompter   func(string) bool // for ask-mode reboots; nil = decline
	Now        func() time.Time  // for watchdog unit name; nil = time.Now
	RebootFlag RebootFlag
	Warnings   *[]string
}

func (c *DeployContext) sleep(d time.Duration) {
	if c.Sleeper == nil {
		time.Sleep(d)
	} else {
		c.Sleeper(d)
	}
}

func (c *DeployContext) now() time.Time {
	if c.Now == nil {
		return time.Now()
	}
	return c.Now()
}

// Deploy is the top-level per-host entry point. Dispatches on Mode. The plan
// carries what the precheck pass already resolved for this host.
func Deploy(ctx *DeployContext, host Host, mode Mode, plan Plan) bool {
	fmt.Printf("\n%s\n", strings.Repeat("=", 60))
	fmt.Printf("Processing %s (mode=%s)\n", host.Name, mode)
	fmt.Printf("%s\n", strings.Repeat("=", 60))

	if !CheckSSHReachable(ctx.Runner, host) {
		fmt.Printf("  ✗ SSH to %s failed\n", host.FQDN())
		return false
	}

	switch mode {
	case ModeSafe:
		return deploySafe(ctx, host, plan)
	case ModeSwitch:
		return deployUnsafe(ctx, host, "switch")
	case ModeBoot:
		return deployUnsafe(ctx, host, "boot")
	}
	return false
}

// deploySafe is the watchdog-protected flow. It begins with the closure already
// present on the target: the pipeline built and copied it before handing the
// host over. Under the armed watchdog we only call switch-to-configuration
// directly on the known system path — no nix eval, no closure transfer.
//
// systemPath cannot drift from what was built. The pipeline builds the
// derivation ResolveToplevels produced, not the flake reference, so nothing
// between the precheck and activation can re-evaluate to a different path —
// which matters here because inputs.self.lastModified reaches the closure of
// every host importing modules/containers/knot-auth.nix or
// modules/desktop/mic-mute.nix, so any change to the source tree moves them.
func deploySafe(ctx *DeployContext, host Host, plan Plan) bool {
	systemPath := plan.SystemPath

	upToDate, priorPath := alreadyDeployed(ctx, host, systemPath)
	if upToDate {
		// Config is already active and persisted as boot default, so the
		// watchdog/activate/persist steps are no-ops. But the host may still
		// owe a reboot (e.g. a prior deploy changed the kernel and the box was
		// never rebooted), so run the post-deploy reboot/health checks.
		fmt.Printf("\n  ✓ %s already running and booting this config — skipping activation\n", host.Name)
		if !handleReboot(ctx, host) {
			return false
		}
		if host.K8sHealthCheck {
			return WaitForK8sReady(ctx.Runner, host, ctx.Sleeper)
		}
		return true
	}

	fmt.Println("\n  [1/8] Cleaning up stale units from prior runs...")
	cleanupStaleUnits(ctx, host)

	fmt.Printf("\n  [2/8] Arming watchdog (%s)...\n", watchdogTimeout)
	unit, ok := armWatchdog(ctx, host, watchdogTimeout)
	if !ok {
		// The arm is not retried, so a "failure" here may still have armed the
		// timer before the connection died. Nothing has been activated yet, so
		// a reboot would be pure downtime — take the unit name armWatchdog
		// built and stop it. Harmless if it was never created.
		disarmWatchdog(ctx, host, unit)
		fmt.Println("  FATAL: cannot proceed without watchdog protection")
		return false
	}

	fmt.Println("\n  [3/8] Activating (switch-to-configuration test)...")
	testTimedOut := false
	if !activate(ctx, host, systemPath, "test", &testTimedOut) {
		fmt.Printf("  Activation failed. Watchdog will reboot %s in <=%s\n",
			host.Name, watchdogTimeout)
		return false
	}

	fmt.Println("\n  [4/8] Verifying connectivity...")
	if !VerifyConnectivity(ctx.Runner, host, ctx.Sleeper) {
		fmt.Printf("  Connectivity failed. Watchdog will reboot %s in <=%s\n",
			host.Name, watchdogTimeout)
		return false
	}

	fmt.Println("\n  [5/8] Verifying active system path matches build...")
	if ok, got := verifyActivePath(ctx, host, systemPath); !ok {
		// Step 6 has not run, so the boot default is still the one the host
		// came up on. A watchdog reboot can therefore only land it back on the
		// generation named by priorPath. Where we can see that is exactly where
		// the host already is, the reboot buys nothing but downtime — release
		// it. An unreadable or unrecognised path is a state we can't account
		// for, so there the watchdog stays.
		if got != "" && got == priorPath {
			fmt.Printf("  Activation did not take effect; %s is still on its previous\n"+
				"  generation and reachable. Nothing was persisted — releasing the\n"+
				"  watchdog rather than rebooting to the config it already runs.\n"+
				"  Investigate the activation failure, then re-run: deploy --hosts %s\n",
				host.Name, host.Name)
			disarmWatchdog(ctx, host, unit)
			return false
		}
		fmt.Printf("  Watchdog will reboot %s in <=%s\n", host.Name, watchdogTimeout)
		return false
	}

	fmt.Println("\n  [6/8] Persisting as boot default...")
	if testTimedOut {
		clearRebuildUnit(ctx, host)
	}
	if !persistBoot(ctx, host, systemPath) {
		fmt.Println("  Persist FAILED — config is active but not persisted.")
		disarmWatchdog(ctx, host, unit)
		return false
	}

	fmt.Println("\n  [7/8] Disarming watchdog...")
	disarmWatchdog(ctx, host, unit)

	fmt.Println("\n  [8/8] Post-deploy checks...")
	if !handleReboot(ctx, host) {
		return false
	}
	if host.K8sHealthCheck {
		if !WaitForK8sReady(ctx.Runner, host, ctx.Sleeper) {
			return false
		}
	}
	fmt.Printf("\n  ✓ %s deployed and persisted successfully\n", host.Name)
	return true
}

// deployUnsafe handles --mode switch and --mode boot: a single nixos-rebuild
// call with no watchdog. Used for debugging or for changes (e.g. dbus impl
// switch) where 'boot' must be persisted before any activation.
func deployUnsafe(ctx *DeployContext, host Host, nrMode string) bool {
	fmt.Printf("\n  [1/3] nixos-rebuild %s...\n", nrMode)
	cctx, cancel := WithTimeout(10 * time.Minute)
	defer cancel()
	argv := []string{
		"nixos-rebuild", nrMode,
		"--flake", ".#" + host.FlakeName,
		"--target-host", host.FQDN(),
		"--use-substitutes",
		"--sudo",
		"--no-reexec",
	}
	res := ctx.Runner.Run(cctx, argv, RunOpts{Stream: true, Env: nixSSHOptsFor(ctx.Runner)})
	// `switch` activates, and activation can restart networkd underneath the
	// connection — the same reason activate() drops the master.
	dropSSHMaster(ctx.Runner, host)
	if res.Failed() {
		fmt.Printf("  ✗ nixos-rebuild %s failed\n", nrMode)
		return false
	}

	fmt.Println("\n  [2/3] Post-deploy checks...")
	// In --mode boot nothing is activated, so there is nothing to compare
	// against — a reboot is owed by definition. parseArgs restricts --reboot to
	// never|always here, so no detection is run.
	if nrMode == "boot" {
		if !applyReboot(ctx, host, true) {
			return false
		}
	} else if !handleReboot(ctx, host) {
		return false
	}

	fmt.Println("\n  [3/3] K8s health (if applicable)...")
	if host.K8sHealthCheck {
		if !WaitForK8sReady(ctx.Runner, host, ctx.Sleeper) {
			return false
		}
	}
	fmt.Printf("  ✓ %s deployed (mode=%s)\n", host.Name, nrMode)
	return true
}

// cleanupStaleUnits removes leftover units from prior failed/interrupted runs:
//   - deploy-watchdog-* timers/services that were never disarmed
//   - nixos-rebuild-switch-to-configuration.service in a failed state
//
// All calls are best-effort; missing units are not an error. Glob patterns
// are supported by systemctl natively.
func cleanupStaleUnits(ctx *DeployContext, host Host) {
	cmd := strings.Join([]string{
		"sudo systemctl stop 'deploy-watchdog-*.timer' 'deploy-watchdog-*.service' 2>/dev/null || true",
		"sudo systemctl reset-failed 'deploy-watchdog-*' 2>/dev/null || true",
		"sudo systemctl stop nixos-rebuild-switch-to-configuration.service 2>/dev/null || true",
		"sudo systemctl reset-failed nixos-rebuild-switch-to-configuration.service 2>/dev/null || true",
	}, "; ")
	SSHRun(ctx.Runner, host, cmd, 15*time.Second)
}

// clearRebuildUnit is the narrower cleanup used mid-flow when a 'test'
// activation disconnected and we need to ensure the rebuild service isn't
// stuck before invoking the boot step.
func clearRebuildUnit(ctx *DeployContext, host Host) {
	cmd := strings.Join([]string{
		"sudo systemctl stop nixos-rebuild-switch-to-configuration.service",
		"sudo systemctl reset-failed nixos-rebuild-switch-to-configuration.service",
	}, "; ")
	SSHRun(ctx.Runner, host, cmd, 10*time.Second)
}

func armWatchdog(ctx *DeployContext, host Host, timeout time.Duration) (string, bool) {
	unit := fmt.Sprintf("deploy-watchdog-%d", ctx.now().Unix())
	cmd := fmt.Sprintf("sudo systemd-run --unit=%s --on-active=%ds systemctl reboot",
		unit, int(timeout.Seconds()))
	// Deliberately not retried: if the first attempt armed the timer before the
	// connection died, a second would fail with "unit already exists" and abort
	// a deploy whose watchdog is live. The unit name is returned either way so
	// the caller can stop such a timer rather than leave it to the next run's
	// cleanupStaleUnits.
	res := SSHRunOnce(ctx.Runner, host, cmd, 30*time.Second)
	if res.Failed() {
		fmt.Printf("  ✗ could not arm watchdog: %s\n", strings.TrimSpace(res.Stderr))
		return unit, false
	}
	fmt.Printf("  ✓ watchdog armed [unit=%s]\n", unit)
	return unit, true
}

func disarmWatchdog(ctx *DeployContext, host Host, unit string) {
	// Both ".timer" and the bare unit name — depending on systemd version
	// either form may be the one that exists. Sequenced rather than passed as
	// two units to one systemctl: this is the call that stops a live reboot
	// timer, so it must not depend on how systemctl treats a missing unit
	// named alongside a present one.
	SSHRun(ctx.Runner, host, strings.Join([]string{
		"sudo systemctl stop " + unit + ".timer 2>/dev/null || true",
		"sudo systemctl stop " + unit,
	}, "; "), 30*time.Second)
}

// activate runs switch-to-configuration directly on the known system path.
// If the SSH connection drops mid-call (sysinit-reactivation.target can kill
// networkd briefly), we wait and ping-check — if the host is reachable we
// assume activation succeeded and set *timedOut so the caller can clear the
// stale unit before the boot step.
func activate(ctx *DeployContext, host Host, systemPath, sub string, timedOut *bool) bool {
	cmd := fmt.Sprintf("sudo %s/bin/switch-to-configuration %s", systemPath, sub)
	// Not retried: this call does its own disconnect handling below, and it
	// must distinguish "activation disconnected us" from "activation failed".
	res := SSHRunOnce(ctx.Runner, host, cmd, activationTimeout)
	// Unconditionally discard the master, success or not. Activation restarts
	// networkd, and an exit status of 0 does not mean the connection survived —
	// a master left pointing at a dropped TCP session looks alive and would
	// stall the connectivity check that gates the watchdog.
	dropSSHMaster(ctx.Runner, host)
	if !res.Failed() {
		fmt.Printf("  ✓ switch-to-configuration %s succeeded\n", sub)
		return true
	}
	if sub == "test" {
		// Sub-second wait for networkd to settle, then probe.
		ctx.sleep(5 * time.Second)
		if CheckSSHReachableDirect(ctx.Runner, host) {
			fmt.Printf("  ⚠ activation disconnected but host reachable — assuming success\n")
			*timedOut = true
			return true
		}
	}
	fmt.Printf("  ✗ switch-to-configuration %s failed\n", sub)
	return false
}

// alreadyDeployed reports whether the host's active system AND boot default
// both already point at systemPath, meaning there is nothing to deploy. It also
// returns the active path, which deploySafe keeps as the generation to compare
// against if activation later turns out not to have taken effect.
//
// /run/current-system is a direct symlink to the toplevel store path (matching
// what verifyActivePath relies on). /nix/var/nix/profiles/system points at a
// system-N-link generation, so we resolve it with `readlink -f` to reach the
// toplevel for comparison.
func alreadyDeployed(ctx *DeployContext, host Host, systemPath string) (bool, string) {
	return hostAtPath(ctx.Runner, host, systemPath)
}

// hostAtPath is the Runner-level form of alreadyDeployed, shared with the
// precheck pass so both answer "is this host up to date?" identically.
//
// An empty systemPath is never a match: two failed readlinks both trim to ""
// and would otherwise look like agreement.
func hostAtPath(r Runner, host Host, systemPath string) (bool, string) {
	active := activeSystemPath(r, host)
	boot := SSHRun(r, host, "readlink -f /nix/var/nix/profiles/system", 15*time.Second)
	if systemPath == "" {
		return false, active
	}
	return active == systemPath && strings.TrimSpace(boot.Stdout) == systemPath, active
}

// activeSystemPath reads the host's live toplevel, or "" if it can't be read.
func activeSystemPath(r Runner, host Host) string {
	res := SSHRun(r, host, "readlink /run/current-system", 15*time.Second)
	return strings.TrimSpace(res.Stdout)
}

// verifyActivePath reports whether the host is running expected, along with the
// path it is actually running. The caller needs that path, not just the bool:
// whether a mismatch warrants leaving the watchdog armed depends on which other
// generation the host landed on.
func verifyActivePath(ctx *DeployContext, host Host, expected string) (bool, string) {
	got := activeSystemPath(ctx.Runner, host)
	if got == "" {
		fmt.Println("  ✗ could not read /run/current-system")
		return false, ""
	}
	if got != expected {
		fmt.Printf("  ✗ active path %s != expected %s\n", got, expected)
		return false, got
	}
	fmt.Println("  ✓ active path matches build")
	return true, got
}

func persistBoot(ctx *DeployContext, host Host, systemPath string) bool {
	cmd1 := fmt.Sprintf("sudo nix-env --profile /nix/var/nix/profiles/system --set %s", systemPath)
	if res := SSHRun(ctx.Runner, host, cmd1, 30*time.Second); res.Failed() {
		fmt.Println("  ✗ profile set failed")
		return false
	}
	cmd2 := fmt.Sprintf("sudo %s/bin/switch-to-configuration boot", systemPath)
	if res := SSHRun(ctx.Runner, host, cmd2, activationTimeout); res.Failed() {
		fmt.Println("  ✗ switch-to-configuration boot failed")
		return false
	}
	fmt.Println("  ✓ persisted as boot default")
	return true
}

// handleReboot detects whether a reboot is owed and acts on it. Returns false
// only if a reboot was attempted and the host did not come back online.
func handleReboot(ctx *DeployContext, host Host) bool {
	return applyReboot(ctx, host, DetectKernelChange(ctx.Runner, host))
}

// applyReboot resolves the reboot decision for an already-known "changed" and
// acts on it. Split out for --mode boot, which knows a reboot is owed without
// detecting anything.
func applyReboot(ctx *DeployContext, host Host, changed bool) bool {
	action := RebootDecide(ctx.RebootFlag, changed)

	switch action {
	case RebootSkip:
		if changed {
			msg := fmt.Sprintf("%s needs reboot (skipped due to --reboot %s)", host.Name, ctx.RebootFlag)
			fmt.Printf("  ⚠ %s\n", msg)
			ctx.appendWarning(msg)
		} else {
			fmt.Printf("  No reboot needed for %s\n", host.Name)
		}
		return true
	case RebootPromptUser:
		if ctx.Prompter == nil || !ctx.Prompter(fmt.Sprintf("  Reboot %s? [y/N]: ", host.Name)) {
			msg := fmt.Sprintf("%s needs reboot (user declined)", host.Name)
			fmt.Printf("  ⚠ %s\n", msg)
			ctx.appendWarning(msg)
			return true
		}
		return rebootAndWait(ctx, host)
	case RebootDo:
		return rebootAndWait(ctx, host)
	}
	return true
}

func (c *DeployContext) appendWarning(s string) {
	if c.Warnings != nil {
		*c.Warnings = append(*c.Warnings, s)
	}
}

const (
	rebootWaitInitial  = 30 * time.Second
	rebootWaitInterval = 10 * time.Second
	rebootWaitMax      = 300 * time.Second
)

func rebootAndWait(ctx *DeployContext, host Host) bool {
	fmt.Printf("  Rebooting %s...\n", host.FQDN())
	// SSH will drop; ignore errors. Not retried, for the same reason: the
	// connection dying here is the expected outcome, not a fault to redial.
	SSHRunOnce(ctx.Runner, host, "sudo systemctl reboot", 10*time.Second)
	// The host is on its way down, so the master is about to point at nothing.
	dropSSHMaster(ctx.Runner, host)

	fmt.Printf("  Waiting %s for %s to start rebooting...\n", rebootWaitInitial, host.FQDN())
	ctx.sleep(rebootWaitInitial)

	deadline := ctx.now().Add(rebootWaitMax)
	for ctx.now().Before(deadline) {
		// Each poll dials its own connection: "has the host come back?" is a
		// question only a fresh handshake can answer.
		if CheckSSHReachableDirect(ctx.Runner, host) {
			fmt.Printf("  ✓ %s back online\n", host.FQDN())
			return true
		}
		fmt.Printf("  %s not yet reachable, waiting %s...\n", host.FQDN(), rebootWaitInterval)
		ctx.sleep(rebootWaitInterval)
	}
	fmt.Printf("  ✗ %s did not come back online within %s\n", host.FQDN(), rebootWaitMax)
	return false
}
