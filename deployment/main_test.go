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
	if got.Reboot != RebootFlagAuto {
		t.Errorf("default reboot = %q, want auto", got.Reboot)
	}
	if len(got.Hosts) != 0 {
		t.Errorf("default hosts = %v, want empty", got.Hosts)
	}
}

func TestParseArgsHosts(t *testing.T) {
	got, err := parseArgs([]string{"--hosts", "router,ro, skyforge"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"router", "ro", "skyforge"}
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
	got, err := parseArgs([]string{"--mode", "boot", "--reboot", "always", "--hosts", "tarrasque"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Mode != ModeBoot || got.Reboot != RebootFlagAlways || got.Hosts[0] != "tarrasque" {
		t.Errorf("got %+v", got)
	}
}

func TestParseArgsRejectsPositional(t *testing.T) {
	if _, err := parseArgs([]string{"extra"}); err == nil {
		t.Fatal("expected error for positional args")
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
