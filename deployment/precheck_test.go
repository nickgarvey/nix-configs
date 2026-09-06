package main

import (
	"strings"
	"testing"
)

const precheckPath = "/nix/store/abc123-nixos-system-test-25.11"

// upToDateResponses makes both readlinks report path, i.e. the host already
// runs and boots it.
func upToDateResponses(path string) []FakeResponse {
	return []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
		{Match: MatchContains("readlink", "profiles/system"), Result: RunResult{Stdout: path + "\n"}},
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: path + "\n"}},
	}
}

func precheckOne(t *testing.T, host Host, path string, force bool, resps []FakeResponse) (PrecheckResult, *FakeRunner) {
	t.Helper()
	fake := &FakeRunner{Responses: resps}
	got := PrecheckAll(fake, []Host{host}, map[string]Toplevel{host.Name: {Drv: path + ".drv", Out: path}}, force)
	if len(got) != 1 {
		t.Fatalf("want 1 result, got %d", len(got))
	}
	return got[0], fake
}

func TestPrecheckUpToDateHostNeedsNoBuild(t *testing.T) {
	host := Host{Name: "lydia", FlakeName: "lydia"}
	res, _ := precheckOne(t, host, precheckPath, false, upToDateResponses(precheckPath))

	if res.Skip {
		t.Errorf("an up-to-date host is still deployed (for the reboot check), got Skip=true")
	}
	if !res.Plan.UpToDate {
		t.Error("want UpToDate=true")
	}
	if res.Plan.SystemPath != precheckPath {
		t.Errorf("want the resolved path carried through, got %q", res.Plan.SystemPath)
	}
}

func TestPrecheckStaleBootDefaultIsNotUpToDate(t *testing.T) {
	host := Host{Name: "lydia", FlakeName: "lydia"}
	resps := []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
		// Running the right system but still booting the old one: not done.
		{Match: MatchContains("readlink", "profiles/system"), Result: RunResult{Stdout: "/nix/store/STALE\n"}},
		{Match: MatchContains("readlink"), Result: RunResult{Stdout: precheckPath + "\n"}},
	}
	res, _ := precheckOne(t, host, precheckPath, false, resps)

	if res.Plan.UpToDate {
		t.Error("a stale boot default must not count as up to date")
	}
}

// An empty path means the resolve failed for this host; two failed readlinks
// both trim to "" and would otherwise compare equal.
func TestPrecheckEmptyPathIsNeverUpToDate(t *testing.T) {
	host := Host{Name: "lydia", FlakeName: "lydia"}
	resps := []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
		{Match: MatchContains("readlink"), Result: RunResult{ExitCode: 1}},
	}
	res, _ := precheckOne(t, host, "", false, resps)

	if res.Plan.UpToDate {
		t.Error("empty system path must not compare equal to empty readlink output")
	}
}

func TestPrecheckUnreachableHostFailsWithoutProbingFurther(t *testing.T) {
	host := Host{Name: "dovahkiin", FlakeName: "dovahkiin"}
	resps := []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{ExitCode: 255}},
	}
	res, fake := precheckOne(t, host, precheckPath, false, resps)

	if !res.Skip || !res.Failed {
		t.Errorf("unreachable host: want Skip and Failed, got Skip=%v Failed=%v", res.Skip, res.Failed)
	}
	if len(fake.CallsContaining("readlink")) != 0 {
		t.Error("should not probe the store of a host it cannot reach")
	}
}

func TestPrecheckActivePrintIsSkippedNotFailed(t *testing.T) {
	host := Host{Name: "skyforge", FlakeName: "skyforge", Groups: []string{"printer"}}
	resps := append([]FakeResponse{
		{Match: MatchContains("curl"), Result: RunResult{
			Stdout: `{"result":{"status":{"print_stats":{"state":"printing"}}}}`,
		}},
	}, upToDateResponses(precheckPath)...)

	res, _ := precheckOne(t, host, precheckPath, false, resps)

	if !res.Skip {
		t.Fatal("want a printing host to be skipped")
	}
	if res.Failed {
		t.Error("an active print is a policy skip, not a failure")
	}
	if !strings.Contains(res.Reason, "printing") {
		t.Errorf("reason should name the printer state, got %q", res.Reason)
	}
}

func TestPrecheckUnreachableMoonrakerSkips(t *testing.T) {
	host := Host{Name: "skyforge", FlakeName: "skyforge", Groups: []string{"printer"}}
	resps := append([]FakeResponse{
		{Match: MatchContains("curl"), Result: RunResult{ExitCode: 7}},
	}, upToDateResponses(precheckPath)...)

	res, _ := precheckOne(t, host, precheckPath, false, resps)

	if !res.Skip || res.Failed {
		t.Errorf("want a fail-closed skip, got Skip=%v Failed=%v", res.Skip, res.Failed)
	}
}

func TestPrecheckForceOverridesActivePrint(t *testing.T) {
	host := Host{Name: "skyforge", FlakeName: "skyforge", Groups: []string{"printer"}}
	resps := append([]FakeResponse{
		{Match: MatchContains("curl"), Result: RunResult{
			Stdout: `{"result":{"status":{"print_stats":{"state":"printing"}}}}`,
		}},
	}, upToDateResponses(precheckPath)...)

	res, fake := precheckOne(t, host, precheckPath, true, resps)

	if res.Skip {
		t.Error("--force must deploy through an active print")
	}
	if len(fake.CallsContaining("curl")) != 0 {
		t.Error("--force should not bother querying moonraker at all")
	}
}

func TestPrecheckNonPrinterHostSkipsMoonraker(t *testing.T) {
	host := Host{Name: "lydia", FlakeName: "lydia", Groups: []string{"infra"}}
	_, fake := precheckOne(t, host, precheckPath, false, upToDateResponses(precheckPath))

	if len(fake.CallsContaining("curl")) != 0 {
		t.Error("only printer-group hosts should be queried for print state")
	}
}

// The probes run concurrently; results must still line up with the input.
func TestPrecheckAllPreservesHostOrder(t *testing.T) {
	hosts := []Host{
		{Name: "fus", FlakeName: "fus"},
		{Name: "ro", FlakeName: "ro"},
		{Name: "dah", FlakeName: "dah"},
		{Name: "wabbajack", FlakeName: "wabbajack"},
		{Name: "talos", FlakeName: "talos"},
		{Name: "lydia", FlakeName: "lydia"},
		{Name: "skyforge", FlakeName: "skyforge"},
		{Name: "dragonsreach", FlakeName: "dragonsreach"},
		{Name: "dovahkiin", FlakeName: "dovahkiin"},
	}
	tops := map[string]Toplevel{}
	for _, h := range hosts {
		tops[h.Name] = Toplevel{Drv: "/nix/store/" + h.Name + ".drv", Out: "/nix/store/" + h.Name}
	}

	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("echo ok"), Result: RunResult{Stdout: "ok\n"}},
	}}
	got := PrecheckAll(fake, hosts, tops, false)

	if len(got) != len(hosts) {
		t.Fatalf("want %d results, got %d", len(hosts), len(got))
	}
	for i, h := range hosts {
		if got[i].Host.Name != h.Name {
			t.Errorf("index %d: want %s, got %s", i, h.Name, got[i].Host.Name)
		}
		if got[i].Plan.SystemPath != tops[h.Name].Out {
			t.Errorf("%s: got path %q, want %q", h.Name, got[i].Plan.SystemPath, tops[h.Name].Out)
		}
		if got[i].Plan.DrvPath != tops[h.Name].Drv {
			t.Errorf("%s: got drv %q, want %q", h.Name, got[i].Plan.DrvPath, tops[h.Name].Drv)
		}
	}
}
