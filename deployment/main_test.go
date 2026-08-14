package main

import (
	"strings"
	"testing"
)

func TestParseArgsDefaults(t *testing.T) {
	got, err := parseArgs(nil)
	if err != nil {
		t.Fatal(err)
	}
	if got.Mode != ModeSafe {
		t.Errorf("default mode = %q, want safe", got.Mode)
	}
	if got.Reboot != RebootFlagNever {
		t.Errorf("default reboot = %q, want never", got.Reboot)
	}
	if len(got.Hosts) != 0 {
		t.Errorf("default hosts = %v, want empty", got.Hosts)
	}
}

func TestParseArgsHosts(t *testing.T) {
	got, err := parseArgs([]string{"--hosts", "dragonsreach,ro, skyforge"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"dragonsreach", "ro", "skyforge"}
	if strings.Join(got.Hosts, ",") != strings.Join(want, ",") {
		t.Errorf("got %v, want %v", got.Hosts, want)
	}
}

func TestParseArgsInvalidMode(t *testing.T) {
	if _, err := parseArgs([]string{"--mode", "yolo"}); err == nil {
		t.Fatal("expected error")
	}
}

func TestParseArgsInvalidReboot(t *testing.T) {
	if _, err := parseArgs([]string{"--reboot", "maybe"}); err == nil {
		t.Fatal("expected error")
	}
}

func TestParseArgsAllValues(t *testing.T) {
	got, err := parseArgs([]string{"--mode", "boot", "--reboot", "always", "--hosts", "talos"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Mode != ModeBoot || got.Reboot != RebootFlagAlways || got.Hosts[0] != "talos" {
		t.Errorf("got %+v", got)
	}
}

// --mode boot stages without activating, so there is nothing to detect: the
// detection-dependent --reboot values are a usage error there.
func TestParseArgsBootRebootRestricted(t *testing.T) {
	for _, argv := range [][]string{
		{"--mode", "boot", "--reboot", "auto"},
		{"--mode", "boot", "--reboot", "ask"},
	} {
		if _, err := parseArgs(argv); err == nil {
			t.Errorf("parseArgs(%v) should error", argv)
		}
	}
	for _, argv := range [][]string{
		{"--mode", "boot"},
		{"--mode", "boot", "--reboot", "never"},
		{"--mode", "boot", "--reboot", "always"},
		{"--mode", "safe", "--reboot", "auto"},
		{"--mode", "safe", "--reboot", "ask"},
		{"--mode", "switch", "--reboot", "ask"},
	} {
		if _, err := parseArgs(argv); err != nil {
			t.Errorf("parseArgs(%v) errored: %v", argv, err)
		}
	}
}

func TestParseArgsSelf(t *testing.T) {
	def, err := parseArgs(nil)
	if err != nil || def.Self {
		t.Fatalf("default Self should be false, got %+v err=%v", def, err)
	}
	got, err := parseArgs([]string{"--self"})
	if err != nil || !got.Self {
		t.Fatalf("--self should set Self=true, got %+v err=%v", got, err)
	}
}

func TestParseArgsRejectsPositional(t *testing.T) {
	if _, err := parseArgs([]string{"extra"}); err == nil {
		t.Fatal("expected error for positional args")
	}
}

func TestParseArgsBuild(t *testing.T) {
	def, err := parseArgs(nil)
	if err != nil || def.Build {
		t.Fatalf("default Build should be false, got %+v err=%v", def, err)
	}
	got, err := parseArgs([]string{"--build"})
	if err != nil || !got.Build {
		t.Fatalf("--build should set Build=true, got %+v err=%v", got, err)
	}
}

func TestParseArgsForce(t *testing.T) {
	def, err := parseArgs(nil)
	if err != nil || def.Force {
		t.Fatalf("default Force should be false, got %+v err=%v", def, err)
	}
	got, err := parseArgs([]string{"--force"})
	if err != nil || !got.Force {
		t.Fatalf("--force should set Force=true, got %+v err=%v", got, err)
	}
}

func TestHostsFlagUsage(t *testing.T) {
	hosts := []Host{
		{Name: "second", Order: 20, Default: true},
		{Name: "optin", Order: 30, Default: false},
		{Name: "first", Order: 10, Default: true},
	}
	got := hostsFlagUsage(hosts)
	want := "Comma-separated host names (default: first,second); opt-in only: optin"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestHostsFlagUsageNoOptIn(t *testing.T) {
	hosts := []Host{{Name: "only", Order: 10, Default: true}}
	got := hostsFlagUsage(hosts)
	want := "Comma-separated host names (default: only)"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestHostsFlagUsageListsRealDefaults(t *testing.T) {
	got := hostsFlagUsage(AllHosts)
	for _, h := range AllHosts {
		if h.Default && !strings.Contains(got, h.Name) {
			t.Errorf("default host %q missing from usage: %s", h.Name, got)
		}
	}
}

func TestParseArgsLocal(t *testing.T) {
	def, err := parseArgs(nil)
	if err != nil || def.Local {
		t.Fatalf("default Local should be false, got %+v err=%v", def, err)
	}
	got, err := parseArgs([]string{"--local"})
	if err != nil || !got.Local {
		t.Fatalf("--local should set Local=true, got %+v err=%v", got, err)
	}
}
