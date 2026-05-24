package main

import "testing"

func TestCheckPrinterIdleStandby(t *testing.T) {
	r := &FakeRunner{Responses: []FakeResponse{{
		Match:  MatchContains("curl", "print_stats"),
		Result: RunResult{Stdout: `{"result":{"status":{"print_stats":{"state":"standby"}}}}`},
	}}}
	idle, state, ok := CheckPrinterIdle(r, Host{Name: "skyforge"})
	if !ok || !idle || state != "standby" {
		t.Fatalf("got idle=%v state=%q ok=%v", idle, state, ok)
	}
}

func TestCheckPrinterIdlePrinting(t *testing.T) {
	r := &FakeRunner{Responses: []FakeResponse{{
		Match:  MatchContains("curl", "print_stats"),
		Result: RunResult{Stdout: `{"result":{"status":{"print_stats":{"state":"printing"}}}}`},
	}}}
	idle, state, ok := CheckPrinterIdle(r, Host{Name: "skyforge"})
	if !ok || idle || state != "printing" {
		t.Fatalf("got idle=%v state=%q ok=%v", idle, state, ok)
	}
}

func TestCheckPrinterIdlePaused(t *testing.T) {
	r := &FakeRunner{Responses: []FakeResponse{{
		Match:  MatchContains("curl", "print_stats"),
		Result: RunResult{Stdout: `{"result":{"status":{"print_stats":{"state":"paused"}}}}`},
	}}}
	idle, _, ok := CheckPrinterIdle(r, Host{Name: "skyforge"})
	if !ok || idle {
		t.Fatalf("paused should not be idle: idle=%v ok=%v", idle, ok)
	}
}

func TestCheckPrinterIdleCurlFailed(t *testing.T) {
	r := &FakeRunner{Responses: []FakeResponse{{
		Match:  MatchContains("curl"),
		Result: RunResult{ExitCode: 7},
	}}}
	_, _, ok := CheckPrinterIdle(r, Host{Name: "skyforge"})
	if ok {
		t.Fatal("expected queryOK=false on curl failure")
	}
}

func TestCheckPrinterIdleBadJSON(t *testing.T) {
	r := &FakeRunner{Responses: []FakeResponse{{
		Match:  MatchContains("curl"),
		Result: RunResult{Stdout: "not json"},
	}}}
	_, _, ok := CheckPrinterIdle(r, Host{Name: "skyforge"})
	if ok {
		t.Fatal("expected queryOK=false on bad JSON")
	}
}

func TestCheckPrinterIdleMissingState(t *testing.T) {
	r := &FakeRunner{Responses: []FakeResponse{{
		Match:  MatchContains("curl"),
		Result: RunResult{Stdout: `{"result":{"status":{"print_stats":{}}}}`},
	}}}
	_, _, ok := CheckPrinterIdle(r, Host{Name: "skyforge"})
	if ok {
		t.Fatal("expected queryOK=false when state field missing")
	}
}
