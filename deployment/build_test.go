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

func TestResolveToplevelsUsesOneCallListingEveryHost(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval"), Result: RunResult{
			Stdout: `{"fus":"/nix/store/aaa-fus","dragonsreach":"/nix/store/bbb-dragonsreach"}`,
		}},
	}}

	if _, err := ResolveToplevels(fake, evalHosts()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(fake.Calls) != 1 {
		t.Fatalf("want exactly 1 nix invocation for the whole fleet, got %d:\n%s",
			len(fake.Calls), strings.Join(joinedCalls(fake), "\n"))
	}
	argv := strings.Join(fake.Calls[0], " ")
	for _, want := range []string{"nix eval", "--json", ".#nixosConfigurations", `"fus"`, `"dragonsreach"`} {
		if !strings.Contains(argv, want) {
			t.Errorf("argv missing %q: %s", want, argv)
		}
	}
}

func TestResolveToplevelsKeysByHostNameNotFlakeName(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval"), Result: RunResult{
			Stdout: `{"fus":"/nix/store/aaa-fus","dragonsreach":"/nix/store/bbb-dragonsreach"}`,
		}},
	}}

	paths, err := ResolveToplevels(fake, evalHosts())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := paths["fus"]; got != "/nix/store/aaa-fus" {
		t.Errorf("fus: got %q", got)
	}
	// Keyed by Host.Name, resolved via Host.FlakeName.
	if got := paths["router"]; got != "/nix/store/bbb-dragonsreach" {
		t.Errorf("router: got %q", got)
	}
	if _, ok := paths["dragonsreach"]; ok {
		t.Error("result should be keyed by Host.Name, not FlakeName")
	}
}

func TestResolveToplevelsErrorsOnMissingHost(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval"), Result: RunResult{
			Stdout: `{"fus":"/nix/store/aaa-fus"}`,
		}},
	}}

	_, err := ResolveToplevels(fake, evalHosts())
	if err == nil {
		t.Fatal("expected an error when a host has no path")
	}
	// A silently-missing path would mean deploying an empty system path.
	if !strings.Contains(err.Error(), "router") {
		t.Errorf("error should name the missing host, got: %v", err)
	}
}

func TestResolveToplevelsErrorsOnEvalFailure(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
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
}

func TestResolveToplevelsErrorsOnGarbageOutput(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: MatchContains("nix", "eval"), Result: RunResult{Stdout: "not json"}},
	}}
	if _, err := ResolveToplevels(fake, evalHosts()); err == nil {
		t.Fatal("expected an error on unparseable output")
	}
}

func TestResolveToplevelsEmptyHostListRunsNothing(t *testing.T) {
	fake := &FakeRunner{}
	paths, err := ResolveToplevels(fake, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(paths) != 0 || len(fake.Calls) != 0 {
		t.Errorf("want no paths and no calls, got %v / %d calls", paths, len(fake.Calls))
	}
}
