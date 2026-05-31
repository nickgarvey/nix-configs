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
		// nix eval -> system path
		{Match: MatchContains("nix", "eval"), Result: RunResult{Stdout: systemPath}},
		// readlink /run/current-system returns expected path
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: systemPath + "\n"}},
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

	if !Deploy(ctx, host, ModeSafe) {
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

	if !Deploy(ctx, host, ModeSafe) {
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

	if Deploy(ctx, host, ModeSafe) {
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

	if Deploy(ctx, host, ModeSafe) {
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

func TestSafeDeployArmFailureAbortsEarly(t *testing.T) {
	host := AllHosts[1]
	host.K8sHealthCheck = false

	resps := []FakeResponse{
		{Match: MatchContains("systemd-run"), Result: RunResult{ExitCode: 1, Stderr: "permission denied"}},
	}
	resps = append(resps, buildOKResponses(fakeSystemPath)...)
	fake := &FakeRunner{Responses: resps}
	ctx := testCtx(fake)

	if Deploy(ctx, host, ModeSafe) {
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

	if Deploy(ctx, host, ModeSafe) {
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

	if !Deploy(ctx, host, ModeSwitch) {
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
	host.Reboot = RebootNever // suppress reboot from assumeNeeded
	fake := &FakeRunner{Responses: buildOKResponses(fakeSystemPath)}
	ctx := testCtx(fake)

	if !Deploy(ctx, host, ModeBoot) {
		t.Fatal("expected success")
	}
	joined := joinedCalls(fake)
	if !contains(joined, "nixos-rebuild boot") {
		t.Errorf("expected 'nixos-rebuild boot', got %v", joined)
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
	if strings.Contains(joined, "nix") && strings.Contains(joined, "eval") {
		return RunResult{Stdout: p.systemPath}
	}
	if strings.Contains(joined, "readlink") {
		return RunResult{Stdout: p.systemPath + "\n"}
	}
	return RunResult{}
}
