package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// countingRunner returns a scripted result based on the call index for
// invocations matching `match`. Useful for testing retry/polling logic.
type countingRunner struct {
	match    func([]string) bool
	results  []RunResult // by call index (matched calls only)
	default_ RunResult   // for non-matching calls
	count    int
}

func (c *countingRunner) Run(_ context.Context, argv []string, _ RunOpts) RunResult {
	if c.match == nil || c.match(argv) {
		i := c.count
		c.count++
		if i < len(c.results) {
			return c.results[i]
		}
		// Past the scripted list: keep returning the last one.
		if len(c.results) > 0 {
			return c.results[len(c.results)-1]
		}
	}
	return c.default_
}

func TestK8sHealthPollingReadyAfterRetries(t *testing.T) {
	r := &countingRunner{
		match: MatchContains("kubectl"),
		results: []RunResult{
			{Stdout: "NotReady"},
			{Stdout: "NotReady"},
			{Stdout: "True"},
		},
	}
	host := Host{Name: "ro"}
	if !WaitForK8sReady(r, host, func(time.Duration) {}) {
		t.Fatalf("expected ready; count=%d", r.count)
	}
	if r.count != 3 {
		t.Errorf("expected 3 kubectl calls, got %d", r.count)
	}
}

func TestK8sHealthPollingNeverReady(t *testing.T) {
	r := &countingRunner{
		match:   MatchContains("kubectl"),
		results: []RunResult{{Stdout: "NotReady"}},
	}
	host := Host{Name: "ro"}
	if WaitForK8sReady(r, host, func(time.Duration) {}) {
		t.Fatal("expected failure")
	}
	if r.count != k8sHealthRetries {
		t.Errorf("expected %d calls, got %d", k8sHealthRetries, r.count)
	}
}

func TestVerifyConnectivityRouterUsesRouterChecks(t *testing.T) {
	dragonsreach := Host{
		Name: "dragonsreach", SSHAddress: "10.28.0.1",
		ConnChecks: []ConnCheck{CheckSSH, CheckPingInternet, CheckDNS, CheckIPv6Tunnel, CheckIPv6Internet},
	}
	fake := &FakeRunner{
		Responses: []FakeResponse{
			{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
			{Match: func([]string) bool { return true }, Result: RunResult{}},
		},
	}
	if !VerifyConnectivity(fake, dragonsreach, func(time.Duration) {}) {
		t.Fatal("expected verify to succeed with all-OK fake")
	}
	joined := joinedCalls(fake)
	for _, want := range []string{
		"ping -c 3 -W 5 1.1.1.1",
		"getent hosts google.com",
		"ping -6 -c 3 -W 5 2001:470:66:35::1",
		"ping -6 -c 3 -W 5 2001:4860:4860::8888",
	} {
		if !contains(joined, want) {
			t.Errorf("dragonsreach checks missing %q in: %v", want, joined)
		}
	}
}

func TestVerifyConnectivityDefaultHostSkipsRouterChecks(t *testing.T) {
	h := Host{
		Name: "talos",
		ConnChecks: []ConnCheck{CheckSSH, CheckPingGateway},
	}
	fake := &FakeRunner{
		Responses: []FakeResponse{
			{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
			{Match: func([]string) bool { return true }, Result: RunResult{}},
		},
	}
	if !VerifyConnectivity(fake, h, func(time.Duration) {}) {
		t.Fatal("expected verify to succeed")
	}
	joined := joinedCalls(fake)
	for _, banned := range []string{"getent", "1.1.1.1", "2001:4860"} {
		if contains(joined, banned) {
			t.Errorf("default host should not run %q: %v", banned, joined)
		}
	}
}

func TestVerifyConnectivityRetriesOnFailure(t *testing.T) {
	h := Host{Name: "x", ConnChecks: []ConnCheck{CheckSSH}}
	r := &countingRunner{
		// SSH check fails first call, succeeds second.
		match: func([]string) bool { return true },
		results: []RunResult{
			{ExitCode: 1},
			{Stdout: "ok\n"},
		},
	}
	if !VerifyConnectivity(r, h, func(time.Duration) {}) {
		t.Fatalf("expected success after retries; count=%d", r.count)
	}
	if r.count != 2 {
		t.Errorf("want 2 calls, got %d", r.count)
	}
}

func TestVerifyConnectivityGivesUp(t *testing.T) {
	h := Host{Name: "x", ConnChecks: []ConnCheck{CheckSSH}}
	r := &countingRunner{
		match:   func([]string) bool { return true },
		results: []RunResult{{ExitCode: 1}},
	}
	if VerifyConnectivity(r, h, func(time.Duration) {}) {
		t.Fatal("expected failure")
	}
	if r.count != verifyRetries {
		t.Errorf("want %d calls, got %d", verifyRetries, r.count)
	}
}

func joinedCalls(f *FakeRunner) []string {
	out := make([]string, len(f.Calls))
	for i, c := range f.Calls {
		out[i] = strings.Join(c, " ")
	}
	return out
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if strings.Contains(s, needle) {
			return true
		}
	}
	return false
}
