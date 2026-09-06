package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// systemPath is a stable fake nix store path used across deploy tests.
const fakeSystemPath = "/nix/store/abc123-nixos-system-test-25.11"

func testCtx(r Runner) *DeployContext {
	return &DeployContext{
		Runner:     r,
		Sleeper:    func(time.Duration) {},
		Now:        func() time.Time { return time.Unix(1700000000, 0) },
		RebootFlag: RebootFlagNever,
	}
}

// buildOKResponses returns the canonical responses for a happy-path safe
// deploy. Tests overlay additional matchers in front for specific behaviors.
func buildOKResponses(systemPath string) []FakeResponse {
	return []FakeResponse{
		// SSH reachable check
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
		// boot default starts stale so the happy path does NOT trip the
		// already-deployed skip (must precede the generic readlink matcher)
		{Match: MatchContains("readlink", "profiles/system"), Result: RunResult{Stdout: "/nix/store/STALE-system\n"}},
		// readlink /run/current-system returns expected path
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: systemPath + "\n"}},
		// Post-build system path query
		{Match: MatchContains("nix eval", "--raw"), Result: RunResult{Stdout: systemPath}},
		// Kernel detection: no change
		{Match: MatchContains("uname -r"), Result: RunResult{Stdout: "6.6.50\n"}},
		{Match: MatchContains("kernel-modules"), Result: RunResult{Stdout: "6.6.50\n"}},
		{Match: MatchContains("booted-system/kernel-params"), Result: RunResult{Stdout: "quiet\n"}},
		{Match: MatchContains("current-system/kernel-params"), Result: RunResult{Stdout: "quiet\n"}},
		// Default for everything else (build, arm, activate, persist, disarm)
		{Match: func([]string) bool { return true }, Result: RunResult{}},
	}
}

func TestSafeDeployHappyPath(t *testing.T) {
	host := AllHosts[1] // ro
	fake := &FakeRunner{Responses: buildOKResponses(fakeSystemPath)}
	ctx := testCtx(fake)

	// k8s health: skip via removing the K8sHealthCheck field for this test
	host.K8sHealthCheck = false

	if !Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success")
	}

	calls := joinedCalls(fake)
	// Required call sequence (substring matches, in order):
	wantOrder := []string{
		"echo ok",                                                          // initial SSH check
		"nixos-rebuild build",                                              // step 1
		"systemd-run --unit=deploy-watchdog-1700000000 --on-active=120s",   // step 2
		"switch-to-configuration test",                                     // step 3
		"readlink /run/current-system",                                     // step 5
		"nix-env --profile /nix/var/nix/profiles/system --set " + fakeSystemPath, // step 6
		"switch-to-configuration boot",                                     // step 6
		"systemctl stop deploy-watchdog-1700000000",                        // step 7
	}
	assertOrder(t, calls, wantOrder)
}

func TestSafeDeploySkipsIfAlreadyDeployed(t *testing.T) {
	host := AllHosts[1] // ro
	host.K8sHealthCheck = false

	// Both the active system and the boot default already point at the built
	// path, so deploySafe should short-circuit after the build.
	resps := []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
		// readlink -f /nix/var/nix/profiles/system (boot default)
		{Match: MatchContains("readlink", "profiles/system"), Result: RunResult{Stdout: fakeSystemPath + "\n"}},
		// readlink /run/current-system (active)
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: fakeSystemPath + "\n"}},
		{Match: MatchContains("nix eval", "--raw"), Result: RunResult{Stdout: fakeSystemPath}},
		{Match: func([]string) bool { return true }, Result: RunResult{}},
	}
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)

	if !Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success via already-deployed skip")
	}

	calls := joinedCalls(fake)
	for _, forbidden := range []string{
		"systemd-run",                  // watchdog armed
		"switch-to-configuration test", // activation
		"nix-env --profile",            // persist profile
		"switch-to-configuration boot", // persist boot
	} {
		if contains(calls, forbidden) {
			t.Errorf("expected skip to avoid %q, but it ran.\nCalls:\n%s",
				forbidden, strings.Join(calls, "\n"))
		}
	}
}

func TestSafeDeploySkipStillRebootsWhenOwed(t *testing.T) {
	host := AllHosts[1] // ro
	host.K8sHealthCheck = false

	// Active + boot already match the build (skip path), but the running
	// kernel differs from the activated config, so a reboot is still owed.
	resps := []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
		{Match: MatchContains("readlink", "profiles/system"), Result: RunResult{Stdout: fakeSystemPath + "\n"}},
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: fakeSystemPath + "\n"}},
		{Match: MatchContains("nix eval", "--raw"), Result: RunResult{Stdout: fakeSystemPath}},
		// running kernel != activated kernel -> reboot needed
		{Match: MatchContains("uname -r"), Result: RunResult{Stdout: "6.6.50\n"}},
		{Match: MatchContains("kernel-modules"), Result: RunResult{Stdout: "6.6.99\n"}},
		{Match: func([]string) bool { return true }, Result: RunResult{}},
	}
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)
	ctx.RebootFlag = RebootFlagAuto

	if !Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success (skip + reboot)")
	}

	calls := joinedCalls(fake)
	// Skipped the redundant work...
	for _, forbidden := range []string{"systemd-run", "switch-to-configuration test", "nix-env --profile"} {
		if contains(calls, forbidden) {
			t.Errorf("expected skip to avoid %q, but it ran", forbidden)
		}
	}
	// ...but still rebooted.
	if !contains(calls, "systemctl reboot") {
		t.Errorf("expected an owed reboot to be issued.\nCalls:\n%s", strings.Join(calls, "\n"))
	}
}

func TestSafeDeployActivationTimeoutHostReachable(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	// Activation 'test' fails but echo ok still succeeds → testTimedOut path.
	resps := []FakeResponse{
		{Match: MatchContains("switch-to-configuration test"), Result: RunResult{TimedOut: true}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)

	if !Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success via testTimedOut recovery")
	}
	// Must have cleared the unit a second time before persist.
	clears := 0
	for _, c := range joinedCalls(fake) {
		if strings.Contains(c, "systemctl stop nixos-rebuild-switch-to-configuration") {
			clears++
		}
	}
	if clears < 2 {
		t.Errorf("expected >=2 unit clears (pre-arm + pre-persist), got %d", clears)
	}
}

func TestSafeDeployActivationFailNotReachable(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	// activation fails AND ssh-reachable check after sleep also fails.
	// Trick: the post-failure echo ok call needs to fail. Use a counting runner
	// that returns ok the first time (initial reachability) and fail thereafter.
	cnt := 0
	wrapper := &probeFailRunner{
		echoCount: &cnt,
		systemPath: fakeSystemPath,
	}
	ctx := testCtx(wrapper)

	if Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected failure")
	}
	// Must NOT have called switch-to-configuration boot or disarmed.
	for _, c := range wrapper.calls {
		joined := strings.Join(c, " ")
		if strings.Contains(joined, "switch-to-configuration boot") {
			t.Errorf("should not have persisted: %s", joined)
		}
		if strings.Contains(joined, "systemctl stop deploy-watchdog") {
			t.Errorf("should not have disarmed watchdog: %s", joined)
		}
	}
}

func TestSafeDeployPathMismatchAborts(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	resps := []FakeResponse{
		// readlink returns a DIFFERENT path
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: "/nix/store/wrong-path\n"}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)

	if Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected failure due to path mismatch")
	}
	// Must NOT have persisted or disarmed.
	for _, c := range joinedCalls(fake) {
		if strings.Contains(c, "switch-to-configuration boot") {
			t.Errorf("should not have persisted: %s", c)
		}
		if strings.Contains(c, "systemctl stop deploy-watchdog") {
			t.Errorf("should not have disarmed: %s", c)
		}
	}
}

// The precheck eval and the build are two separate evaluations, so the flake
// source can move between them (a dirty tree re-times inputs.self.lastModified;
// a commit mid-run moves the rev). The path the build produced is the only one
// that exists on the target, so everything downstream must use it.
func TestSafeDeployPrefersBuiltPathOverPlanPath(t *testing.T) {
	host := AllHosts[1] // ro
	host.K8sHealthCheck = false

	const planPath = "/nix/store/stale123-nixos-system-test-25.11"

	resps := []FakeResponse{
		// The post-build eval disagrees with the precheck path.
		{Match: MatchContains("nix eval", "--raw"), Result: RunResult{Stdout: fakeSystemPath}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}

	if !Deploy(testCtx(fake), host, ModeSafe, Plan{SystemPath: planPath}) {
		t.Fatal("expected success using the built path")
	}

	for _, sub := range []string{"switch-to-configuration test", "switch-to-configuration boot", "nix-env --profile"} {
		calls := fake.CallsContaining(sub)
		if len(calls) == 0 {
			t.Fatalf("expected a %q call", sub)
		}
		for _, c := range calls {
			joined := strings.Join(c, " ")
			if !strings.Contains(joined, fakeSystemPath) {
				t.Errorf("expected %q to use the built path, got %s", sub, CallString(c))
			}
			if strings.Contains(joined, planPath) {
				t.Errorf("expected %q to drop the stale precheck path, got %s", sub, CallString(c))
			}
		}
	}
}

// A build that succeeds but whose system path cannot be determined must fail
// before the watchdog is armed: there is no path to activate.
func TestSafeDeployFailsWhenPathQueryFails(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	resps := []FakeResponse{
		{Match: MatchContains("nix eval", "--raw"), Result: RunResult{ExitCode: 1}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}

	if Deploy(testCtx(fake), host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected failure when the system path cannot be determined")
	}
	if len(fake.CallsContaining("systemd-run")) > 0 {
		t.Error("watchdog must not be armed without a known system path")
	}
}
func TestSafeDeployArmFailureAbortsEarly(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	resps := []FakeResponse{
		{Match: MatchContains("systemd-run"), Result: RunResult{ExitCode: 1, Stderr: "permission denied"}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)

	if Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected failure")
	}
	for _, c := range joinedCalls(fake) {
		// The clear-unit call references "nixos-rebuild-switch-to-configuration.service"
		// which contains "switch-to-configuration"; filter for the actual activation form.
		if strings.Contains(c, "/bin/switch-to-configuration") {
			t.Errorf("should not have attempted activation: %s", c)
		}
	}
}

func TestSafeDeployPersistFailureStillDisarms(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	// Persist fails on the nix-env call.
	resps := []FakeResponse{
		{Match: MatchContains("nix-env --profile"), Result: RunResult{ExitCode: 1}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)

	if Deploy(ctx, host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected failure")
	}
	disarmed := false
	for _, c := range joinedCalls(fake) {
		if strings.Contains(c, "systemctl stop deploy-watchdog") {
			disarmed = true
		}
	}
	if !disarmed {
		t.Error("watchdog should be disarmed when persist fails (config is active)")
	}
}

func TestModeDispatchSwitch(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false
	fake := &FakeRunner{Responses: buildOKResponses(fakeSystemPath)}
	ctx := testCtx(fake)

	if !Deploy(ctx, host, ModeSwitch, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success")
	}
	joined := joinedCalls(fake)
	if !contains(joined, "nixos-rebuild switch") {
		t.Errorf("expected 'nixos-rebuild switch', got %v", joined)
	}
	// No watchdog in unsafe mode.
	for _, c := range joined {
		if strings.Contains(c, "systemd-run") || strings.Contains(c, "switch-to-configuration") {
			t.Errorf("unsafe mode should not arm watchdog or call switch-to-configuration: %s", c)
		}
	}
}

func TestModeDispatchBoot(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false
	// testCtx uses --reboot never, so nothing reboots.
	fake := &FakeRunner{Responses: buildOKResponses(fakeSystemPath)}
	ctx := testCtx(fake)

	if !Deploy(ctx, host, ModeBoot, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success")
	}
	joined := joinedCalls(fake)
	if !contains(joined, "nixos-rebuild boot") {
		t.Errorf("expected 'nixos-rebuild boot', got %v", joined)
	}
	assertNoDetection(t, joined)
	if contains(joined, "systemctl reboot") {
		t.Errorf("--reboot never should not reboot, got %v", joined)
	}
}

// Boot mode knows a reboot is owed without detecting anything, so --reboot
// always reboots with no kernel queries.
func TestModeDispatchBootRebootAlways(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false
	fake := &FakeRunner{Responses: buildOKResponses(fakeSystemPath)}
	ctx := testCtx(fake)
	ctx.RebootFlag = RebootFlagAlways

	if !Deploy(ctx, host, ModeBoot, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success")
	}
	joined := joinedCalls(fake)
	if !contains(joined, "systemctl reboot") {
		t.Errorf("--reboot always should reboot, got %v", joined)
	}
	assertNoDetection(t, joined)
}

// assertNoDetection fails if the kernel/params reboot check was run. Boot mode
// stages without activating, so /run/current-system can't answer the question
// and the check is skipped entirely.
func assertNoDetection(t *testing.T, calls []string) {
	t.Helper()
	for _, probe := range []string{"uname -r", "kernel-modules", "kernel-params"} {
		if contains(calls, probe) {
			t.Errorf("boot mode should not run detection, but called %q: %v", probe, calls)
		}
	}
}

// assertOrder verifies that the given substring patterns appear in order
// somewhere in the joined call list.
func assertOrder(t *testing.T, calls []string, patterns []string) {
	t.Helper()
	pi := 0
	for _, c := range calls {
		if pi < len(patterns) && strings.Contains(c, patterns[pi]) {
			pi++
		}
	}
	if pi != len(patterns) {
		t.Errorf("missing pattern %q at position %d.\nCalls:\n%s",
			patterns[pi], pi, strings.Join(calls, "\n"))
	}
}

// probeFailRunner returns ok for the FIRST echo-ok call (initial SSH check)
// and fails subsequent ones. Used to simulate activation-timeout + truly-down.
type probeFailRunner struct {
	echoCount  *int
	systemPath string
	calls      [][]string
}

func (p *probeFailRunner) Run(_ context.Context, argv []string, _ RunOpts) RunResult {
	p.calls = append(p.calls, argv)
	joined := strings.Join(argv, " ")
	if strings.Contains(joined, "echo ok") {
		*p.echoCount++
		if *p.echoCount == 1 {
			return RunResult{Stdout: "ok\n"}
		}
		return RunResult{ExitCode: 255}
	}
	if strings.Contains(joined, "switch-to-configuration test") {
		return RunResult{TimedOut: true}
	}
	if strings.Contains(joined, "profiles/system") {
		// boot default is stale, so the already-deployed skip does not trip
		return RunResult{Stdout: "/nix/store/STALE-system\n"}
	}
	if strings.Contains(joined, "readlink") {
		return RunResult{Stdout: p.systemPath + "\n"}
	}
	return RunResult{}
}

// Every build runs on this machine, so no nixos-rebuild call may offload.
func TestBuildsNeverOffload(t *testing.T) {
	host := AllHosts[1] // ro
	host.K8sHealthCheck = false

	fake := &FakeRunner{Responses: buildOKResponses(fakeSystemPath)}
	if !Deploy(testCtx(fake), host, ModeSafe, Plan{SystemPath: fakeSystemPath}) {
		t.Fatal("expected success")
	}

	buildFake := &FakeRunner{}
	if !BuildOnly(buildFake, host) {
		t.Fatal("expected success")
	}

	for _, f := range []*FakeRunner{fake, buildFake} {
		for _, c := range f.CallsContaining("nixos-rebuild") {
			if strings.Contains(strings.Join(c, " "), "--build-host") {
				t.Errorf("call still offloads: %s", CallString(c))
			}
		}
	}
}

// deployFake is a FakeRunner that carries an ssh control, so the deploy flow
// takes its multiplexed paths and emits `ssh -O exit` where it should.
type deployFake struct {
	*FakeRunner
	ctl *SSHControl
}

func (d deployFake) SSHControl() *SSHControl { return d.ctl }

func newDeployFake(resps []FakeResponse) deployFake {
	return deployFake{
		FakeRunner: &FakeRunner{Responses: resps},
		ctl:        &SSHControl{Dir: "/tmp/deploy-ssh-test"},
	}
}

func masterDrops(f *FakeRunner) int {
	n := 0
	for _, c := range f.Calls {
		for _, a := range c {
			if a == "-O" {
				n++
				break
			}
		}
	}
	return n
}

// Activation restarts networkd, so the master must be discarded even when
// switch-to-configuration exits 0 — a master pointing at a dropped session
// looks alive and would stall the connectivity check that gates the watchdog.
func TestActivateDropsMasterOnSuccess(t *testing.T) {
	fake := newDeployFake(buildOKResponses(fakeSystemPath))
	timedOut := false
	if !activate(testCtx(fake), AllHosts[1], fakeSystemPath, "test", &timedOut) {
		t.Fatal("expected activation to succeed")
	}
	if got := masterDrops(fake.FakeRunner); got != 1 {
		t.Errorf("expected the master to be dropped once, got %d", got)
	}
}

// The reboot wait must not question a socket about a host that is going down:
// the master is dropped, and each poll dials its own connection.
func TestRebootDropsMasterAndPollsDirectly(t *testing.T) {
	fake := newDeployFake(buildOKResponses(fakeSystemPath))
	if !rebootAndWait(testCtx(fake), AllHosts[1]) {
		t.Fatal("expected the host to come back")
	}
	if got := masterDrops(fake.FakeRunner); got != 1 {
		t.Errorf("expected the master to be dropped once, got %d", got)
	}
	probes := 0
	for _, c := range joinedCalls(fake.FakeRunner) {
		if strings.Contains(c, "echo ok") {
			probes++
			if !strings.Contains(c, "ControlPath=none") {
				t.Errorf("reboot probe must bypass the master: %s", c)
			}
		}
	}
	if probes == 0 {
		t.Error("expected at least one reachability probe")
	}
}

// The closure copy shares our master rather than opening its own.
func TestBuildAndCopyPassesControlToNixosRebuild(t *testing.T) {
	fake := newDeployFake([]FakeResponse{
		{Match: MatchContains("nix", "eval"), Result: RunResult{Stdout: fakeSystemPath}},
		{Match: func([]string) bool { return true }, Result: RunResult{}},
	})
	if _, ok := buildAndCopy(testCtx(fake), AllHosts[1]); !ok {
		t.Fatal("expected build to succeed")
	}
	env := nixSSHOptsFor(fake)
	if len(env) != 1 || !strings.Contains(env[0], "ControlPath=/tmp/deploy-ssh-test/%C") {
		t.Errorf("nixos-rebuild must inherit our control path, got %v", env)
	}
}
