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

// Deploy is the top-level per-host entry point. Dispatches on Mode.
func Deploy(ctx *DeployContext, host Host, mode Mode) bool {
	fmt.Printf("\n%s\n", strings.Repeat("=", 60))
	fmt.Printf("Processing %s (mode=%s, reboot-policy=%s)\n", host.Name, mode, host.Reboot)
	fmt.Printf("%s\n", strings.Repeat("=", 60))

	if !CheckSSHReachable(ctx.Runner, host) {
		fmt.Printf("  ✗ SSH to %s failed\n", host.FQDN())
		return false
	}

	switch mode {
	case ModeSafe:
		return deploySafe(ctx, host)
	case ModeSwitch:
		return deployUnsafe(ctx, host, "switch")
	case ModeBoot:
		return deployUnsafe(ctx, host, "boot")
	}
	return false
}

// deploySafe is the watchdog-protected flow. Slow steps (build + pre-copy to
// target's nix store) happen BEFORE the watchdog is armed. Under the armed
// watchdog we only call switch-to-configuration directly on the known system
// path — no nix eval, no closure transfer.
func deploySafe(ctx *DeployContext, host Host) bool {
	fmt.Println("\n  [1/9] Building on talos and copying closure to target...")
	systemPath, ok := buildAndCopy(ctx, host)
	if !ok {
		return false
	}

	if alreadyDeployed(ctx, host, systemPath) {
		// Config is already active and persisted as boot default, so the
		// watchdog/activate/persist steps are no-ops. But the host may still
		// owe a reboot (e.g. a prior deploy changed the kernel and the box was
		// never rebooted), so run the post-deploy reboot/health checks.
		fmt.Printf("\n  ✓ %s already running and booting this config — skipping activation\n", host.Name)
		if !handleReboot(ctx, host, false) {
			return false
		}
		if host.K8sHealthCheck {
			return WaitForK8sReady(ctx.Runner, host, ctx.Sleeper)
		}
		return true
	}

	fmt.Println("\n  [2/9] Cleaning up stale units from prior runs...")
	cleanupStaleUnits(ctx, host)

	fmt.Printf("\n  [3/9] Arming watchdog (%s)...\n", watchdogTimeout)
	unit, ok := armWatchdog(ctx, host, watchdogTimeout)
	if !ok {
		fmt.Println("  FATAL: cannot proceed without watchdog protection")
		return false
	}

	fmt.Println("\n  [4/9] Activating (switch-to-configuration test)...")
	testTimedOut := false
	if !activate(ctx, host, systemPath, "test", &testTimedOut) {
		fmt.Printf("  Activation failed. Watchdog will reboot %s in <=%s\n",
			host.Name, watchdogTimeout)
		return false
	}

	fmt.Println("\n  [5/9] Verifying connectivity...")
	if !VerifyConnectivity(ctx.Runner, host, ctx.Sleeper) {
		fmt.Printf("  Connectivity failed. Watchdog will reboot %s in <=%s\n",
			host.Name, watchdogTimeout)
		return false
	}

	fmt.Println("\n  [6/9] Verifying active system path matches build...")
	if !verifyActivePath(ctx, host, systemPath) {
		fmt.Printf("  Watchdog will reboot %s in <=%s\n", host.Name, watchdogTimeout)
		return false
	}

	fmt.Println("\n  [7/9] Persisting as boot default...")
	if testTimedOut {
		clearRebuildUnit(ctx, host)
	}
	if !persistBoot(ctx, host, systemPath) {
		fmt.Println("  Persist FAILED — config is active but not persisted.")
		disarmWatchdog(ctx, host, unit)
		return false
	}

	fmt.Println("\n  [8/9] Disarming watchdog...")
	disarmWatchdog(ctx, host, unit)

	fmt.Println("\n  [9/9] Post-deploy checks...")
	if !handleReboot(ctx, host, false) {
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
		"--build-host", BuildHost,
		"--use-substitutes",
		"--sudo",
		"--no-reexec",
	}
	res := ctx.Runner.Run(cctx, argv, RunOpts{Stream: true})
	if res.Failed() {
		fmt.Printf("  ✗ nixos-rebuild %s failed\n", nrMode)
		return false
	}

	fmt.Println("\n  [2/3] Post-deploy checks...")
	// In --mode boot the new system isn't activated, so /run/current-system
	// won't show the bump — assume reboot is needed.
	assumeNeeded := nrMode == "boot"
	if !handleReboot(ctx, host, assumeNeeded) {
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

// buildAndCopy runs `nixos-rebuild build --build-host talos --target-host
// <host> --use-substitutes`. This evaluates+builds on talos and has the
// target pull the closure from talos's harmonia substituter, populating
// the target's nix store BEFORE we arm the watchdog. Returns the system path.
func buildAndCopy(ctx *DeployContext, host Host) (string, bool) {
	cctx, cancel := WithTimeout(30 * time.Minute) // builds can be slow
	defer cancel()
	argv := []string{
		"nixos-rebuild", "build",
		"--flake", ".#" + host.FlakeName,
		"--build-host", BuildHost,
		"--target-host", host.FQDN(),
		"--use-substitutes",
		"--sudo",
		"--no-reexec",
	}
	if res := ctx.Runner.Run(cctx, argv, RunOpts{Stream: true}); res.Failed() {
		fmt.Printf("  ✗ build for %s failed\n", host.FQDN())
		return "", false
	}

	// Eval-only query for the system path. The build above populates the
	// eval cache, so this is fast.
	evalCtx, evalCancel := WithTimeout(30 * time.Second)
	defer evalCancel()
	evalRes := ctx.Runner.Run(evalCtx, []string{
		"nix", "eval", "--raw",
		fmt.Sprintf(".#nixosConfigurations.%s.config.system.build.toplevel.outPath", host.FlakeName),
	}, RunOpts{})
	if evalRes.Failed() {
		fmt.Println("  ✗ could not determine system path after build")
		return "", false
	}
	path := strings.TrimSpace(evalRes.Stdout)
	fmt.Printf("  ✓ built and copied: %s\n", path)
	return path, true
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
	for _, action := range []string{"stop", "reset-failed"} {
		SSHRun(ctx.Runner, host,
			"sudo systemctl "+action+" nixos-rebuild-switch-to-configuration.service",
			10*time.Second)
	}
}

func armWatchdog(ctx *DeployContext, host Host, timeout time.Duration) (string, bool) {
	unit := fmt.Sprintf("deploy-watchdog-%d", ctx.now().Unix())
	cmd := fmt.Sprintf("sudo systemd-run --unit=%s --on-active=%ds systemctl reboot",
		unit, int(timeout.Seconds()))
	res := SSHRun(ctx.Runner, host, cmd, 30*time.Second)
	if res.Failed() {
		fmt.Printf("  ✗ could not arm watchdog: %s\n", strings.TrimSpace(res.Stderr))
		return "", false
	}
	fmt.Printf("  ✓ watchdog armed [unit=%s]\n", unit)
	return unit, true
}

func disarmWatchdog(ctx *DeployContext, host Host, unit string) {
	// Try both ".timer" and bare unit name — depending on systemd version
	// either form may be the one that exists.
	for _, suffix := range []string{".timer", ""} {
		SSHRun(ctx.Runner, host, "sudo systemctl stop "+unit+suffix, 30*time.Second)
	}
}

// activate runs switch-to-configuration directly on the known system path.
// If the SSH connection drops mid-call (sysinit-reactivation.target can kill
// networkd briefly), we wait and ping-check — if the host is reachable we
// assume activation succeeded and set *timedOut so the caller can clear the
// stale unit before the boot step.
func activate(ctx *DeployContext, host Host, systemPath, sub string, timedOut *bool) bool {
	cmd := fmt.Sprintf("sudo %s/bin/switch-to-configuration %s", systemPath, sub)
	res := SSHRun(ctx.Runner, host, cmd, activationTimeout)
	if !res.Failed() {
		fmt.Printf("  ✓ switch-to-configuration %s succeeded\n", sub)
		return true
	}
	if sub == "test" {
		// Sub-second wait for networkd to settle, then probe.
		ctx.sleep(5 * time.Second)
		if CheckSSHReachable(ctx.Runner, host) {
			fmt.Printf("  ⚠ activation disconnected but host reachable — assuming success\n")
			*timedOut = true
			return true
		}
	}
	fmt.Printf("  ✗ switch-to-configuration %s failed\n", sub)
	return false
}

// alreadyDeployed reports whether the host's active system AND boot default
// both already point at systemPath, meaning there is nothing to deploy.
//
// /run/current-system is a direct symlink to the toplevel store path (matching
// what verifyActivePath relies on). /nix/var/nix/profiles/system points at a
// system-N-link generation, so we resolve it with `readlink -f` to reach the
// toplevel for comparison.
func alreadyDeployed(ctx *DeployContext, host Host, systemPath string) bool {
	active := SSHRun(ctx.Runner, host, "readlink /run/current-system", 15*time.Second)
	boot := SSHRun(ctx.Runner, host, "readlink -f /nix/var/nix/profiles/system", 15*time.Second)
	return strings.TrimSpace(active.Stdout) == systemPath &&
		strings.TrimSpace(boot.Stdout) == systemPath
}

func verifyActivePath(ctx *DeployContext, host Host, expected string) bool {
	res := SSHRun(ctx.Runner, host, "readlink /run/current-system", 15*time.Second)
	got := strings.TrimSpace(res.Stdout)
	if got == "" {
		fmt.Println("  ✗ could not read /run/current-system")
		return false
	}
	if got != expected {
		fmt.Printf("  ✗ active path %s != expected %s (watchdog mid-reboot?)\n", got, expected)
		return false
	}
	fmt.Println("  ✓ active path matches build")
	return true
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

// handleReboot resolves the reboot decision and acts on it. Returns false
// only if a reboot was attempted and the host did not come back online.
func handleReboot(ctx *DeployContext, host Host, assumeNeeded bool) bool {
	var changed bool
	if assumeNeeded {
		changed = true
	} else {
		changed = DetectKernelChange(ctx.Runner, host)
	}

	action := RebootDecide(ctx.RebootFlag, host.Reboot, changed)

	switch action {
	case RebootSkip:
		if changed && host.Reboot == RebootNever {
			msg := fmt.Sprintf("%s needs reboot (policy NEVER, reboot manually)", host.Name)
			fmt.Printf("  ⚠ %s\n", msg)
			ctx.appendWarning(msg)
		} else if changed && ctx.RebootFlag == RebootFlagNever {
			msg := fmt.Sprintf("%s needs reboot (skipped due to --reboot never)", host.Name)
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
	// SSH will drop; ignore errors.
	SSHRun(ctx.Runner, host, "sudo systemctl reboot", 10*time.Second)

	fmt.Printf("  Waiting %s for %s to start rebooting...\n", rebootWaitInitial, host.FQDN())
	ctx.sleep(rebootWaitInitial)

	deadline := ctx.now().Add(rebootWaitMax)
	for ctx.now().Before(deadline) {
		if CheckSSHReachable(ctx.Runner, host) {
			fmt.Printf("  ✓ %s back online\n", host.FQDN())
			return true
		}
		fmt.Printf("  %s not yet reachable, waiting %s...\n", host.FQDN(), rebootWaitInterval)
		ctx.sleep(rebootWaitInterval)
	}
	fmt.Printf("  ✗ %s did not come back online within %s\n", host.FQDN(), rebootWaitMax)
	return false
}
