package main

import (
	"strings"
	"testing"
)

func evalHosts() []Host {
	return []Host{
		{Name: "fus", FlakeName: "fus"},
		// A host whose flake attribute differs from its name, so the mapping
		// back from eval output is actually exercised.
		{Name: "router", FlakeName: "dragonsreach"},
	}
}

const (
	fusJSON = `{"drv":"/nix/store/aaa-fus.drv","out":"/nix/store/aaa-fus"}`
	drJSON  = `{"drv":"/nix/store/bbb-dr.drv","out":"/nix/store/bbb-dr"}`
)

// evalRunner answers each host's eval with that host's JSON, matched on the
// flake attribute in its argv. One response per host, because the resolve now
// runs one eval per host rather than a single batched one.
func evalRunner(fus, dragonsreach string) *FakeRunner {
	return &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval", "nixosConfigurations.fus."), Result: RunResult{Stdout: fus}},
		{Match: MatchContains("nix", "eval", "nixosConfigurations.dragonsreach."), Result: RunResult{Stdout: dragonsreach}},
	}}
}

func TestResolveToplevelsEvalsEachHostSeparately(t *testing.T) {
	fake := evalRunner(fusJSON, drJSON)
	if _, err := ResolveToplevels(fake, evalHosts()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// One eval per host is the point: nix evaluation is single-threaded, so a
	// batched eval costs the sum of the hosts rather than the slowest one.
	if len(fake.Calls) != 2 {
		t.Fatalf("want one nix invocation per host, got %d:\n%s",
			len(fake.Calls), strings.Join(joinedCalls(fake), "\n"))
	}
	for _, attr := range []string{"nixosConfigurations.fus.", "nixosConfigurations.dragonsreach."} {
		if len(fake.CallsContaining("nix eval", attr)) != 1 {
			t.Errorf("want exactly one eval naming %s, got:\n%s", attr, strings.Join(joinedCalls(fake), "\n"))
		}
	}
}

func TestEvalArgv(t *testing.T) {
	argv := strings.Join(EvalArgv(Host{Name: "router", FlakeName: "dragonsreach"}), " ")
	for _, want := range []string{
		"nix eval", "--json",
		".#nixosConfigurations.dragonsreach.config.system.build.toplevel",
		"drvPath", "outPath",
		// The eval cache cannot serve this query, and leaving it on makes the
		// concurrent evals contend on its sqlite lock.
		"--option eval-cache false",
	} {
		if !strings.Contains(argv, want) {
			t.Errorf("argv missing %q: %s", want, argv)
		}
	}
}

func TestResolveToplevelsKeysByHostNameNotFlakeName(t *testing.T) {
	tops, err := ResolveToplevels(evalRunner(fusJSON, drJSON), evalHosts())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := tops["fus"]; got.Out != "/nix/store/aaa-fus" || got.Drv != "/nix/store/aaa-fus.drv" {
		t.Errorf("fus: got %+v", got)
	}
	// Keyed by Host.Name, resolved via Host.FlakeName.
	if got := tops["router"]; got.Out != "/nix/store/bbb-dr" || got.Drv != "/nix/store/bbb-dr.drv" {
		t.Errorf("router: got %+v", got)
	}
	if _, ok := tops["dragonsreach"]; ok {
		t.Error("result should be keyed by Host.Name, not FlakeName")
	}
}

// A half-populated entry would mean building one host and activating another's
// path, so both fields must be present.
func TestResolveToplevelsErrorsOnPartialEntry(t *testing.T) {
	for _, tc := range []struct{ name, json string }{
		{"empty", `{}`},
		{"missing drv", `{"out":"/nix/store/bbb-dr"}`},
		{"missing out", `{"drv":"/nix/store/bbb-dr.drv"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ResolveToplevels(evalRunner(fusJSON, tc.json), evalHosts())
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), "router") {
				t.Errorf("error should name the host, got: %v", err)
			}
		})
	}
}

func TestResolveToplevelsErrorsOnEvalFailure(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval", "nixosConfigurations.fus."), Result: RunResult{Stdout: fusJSON}},
		{Match: MatchContains("nix", "eval"), Result: RunResult{
			ExitCode: 1, Stderr: "progress\nerror: attribute 'nope' missing",
		}},
	}}
	_, err := ResolveToplevels(fake, evalHosts())
	if err == nil {
		t.Fatal("expected an error when nix eval fails")
	}
	if !strings.Contains(err.Error(), "attribute 'nope' missing") {
		t.Errorf("error should carry nix's message, got: %v", err)
	}
	// The evals run concurrently, so the message has to say which host failed.
	if !strings.Contains(err.Error(), "router") {
		t.Errorf("error should name the failing host, got: %v", err)
	}
}

// Each host's eval is its own process, so one failure must not hide another.
func TestResolveToplevelsReportsEveryFailingHost(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval"), Result: RunResult{
			ExitCode: 1, Stderr: "error: something broke",
		}},
	}}
	_, err := ResolveToplevels(fake, evalHosts())
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, host := range []string{"fus", "router"} {
		if !strings.Contains(err.Error(), host) {
			t.Errorf("error should name every failing host, missing %q: %v", host, err)
		}
	}
}

func TestResolveToplevelsErrorsOnGarbageOutput(t *testing.T) {
	if _, err := ResolveToplevels(evalRunner(fusJSON, "not json"), evalHosts()); err == nil {
		t.Fatal("expected an error on unparseable output")
	}
}

func TestResolveToplevelsEmptyHostListRunsNothing(t *testing.T) {
	fake := &FakeRunner{}
	tops, err := ResolveToplevels(fake, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tops) != 0 || len(fake.Calls) != 0 {
		t.Errorf("want no paths and no calls, got %v / %d calls", tops, len(fake.Calls))
	}
}

// One invocation for every host is what bounds the build machine: N separate
// nix clients would each get their own max-jobs budget.
func TestBuildArgvIsOneCallOverAllDerivations(t *testing.T) {
	argv := BuildArgv([]string{"/nix/store/a.drv", "/nix/store/b.drv"}, BuildOpts{})
	joined := strings.Join(argv, " ")

	for _, want := range []string{
		"nix build",
		"--keep-going", // one host failing must not abort the others
		"--no-link",
		"/nix/store/a.drv^out",
		"/nix/store/b.drv^out",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv missing %q: %s", want, joined)
		}
	}
	// Derivations, not flake refs: a re-evaluation could produce a different
	// path than the precheck committed to.
	if strings.Contains(joined, "nixosConfigurations") {
		t.Errorf("argv should build derivations, not flake refs: %s", joined)
	}
}

func TestBuildArgvJobFlagsOmittedWhenZero(t *testing.T) {
	joined := strings.Join(BuildArgv([]string{"/nix/store/a.drv"}, BuildOpts{}), " ")
	if strings.Contains(joined, "--max-jobs") || strings.Contains(joined, "--cores") {
		t.Errorf("zero means leave it to nix.conf, got: %s", joined)
	}

	joined = strings.Join(BuildArgv([]string{"/nix/store/a.drv"}, BuildOpts{MaxJobs: 8, Cores: 2}), " ")
	for _, want := range []string{"--max-jobs 8", "--cores 2"} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv missing %q: %s", want, joined)
		}
	}
}

func TestBuildAllWithNoDerivationsRunsNothing(t *testing.T) {
	fake := &FakeRunner{}
	if !BuildAll(fake, nil, BuildOpts{}) {
		t.Error("an empty build should succeed")
	}
	if len(fake.Calls) != 0 {
		t.Errorf("expected no calls, got %v", fake.Calls)
	}
}

func TestBuiltOK(t *testing.T) {
	present := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("path-info"), Result: RunResult{}},
	}}
	if !BuiltOK(present, "/nix/store/aaa") {
		t.Error("exit 0 from path-info means built")
	}

	missing := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("path-info"), Result: RunResult{ExitCode: 1}},
	}}
	if BuiltOK(missing, "/nix/store/aaa") {
		t.Error("exit 1 from path-info means not built")
	}

	if BuiltOK(present, "") {
		t.Error("an empty path is never built")
	}
}
