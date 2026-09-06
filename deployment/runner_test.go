package main

import (
	"strings"
	"testing"
)

// A duplicate KEY= entry is not merely untidy: which one wins depends on the
// consumer (glibc getenv takes the first, Python's os.environ the last), and
// NIX_SSHOPTS is read by both.
func TestMergeEnvReplacesInPlace(t *testing.T) {
	base := []string{"PATH=/bin", "NIX_SSHOPTS=-i /old", "HOME=/home/x"}
	got := mergeEnv(base, []string{"NIX_SSHOPTS=-o ControlPath=/tmp/x/%C"})

	if len(got) != len(base) {
		t.Fatalf("expected no new entries, got %v", got)
	}
	if got[1] != "NIX_SSHOPTS=-o ControlPath=/tmp/x/%C" {
		t.Errorf("expected the existing key replaced in place, got %q", got[1])
	}
	n := 0
	for _, e := range got {
		if strings.HasPrefix(e, "NIX_SSHOPTS=") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("expected exactly one NIX_SSHOPTS entry, got %d in %v", n, got)
	}
}

func TestMergeEnvAppendsNewKey(t *testing.T) {
	got := mergeEnv([]string{"PATH=/bin"}, []string{"NIX_SSHOPTS=-o X=1"})
	if len(got) != 2 || got[1] != "NIX_SSHOPTS=-o X=1" {
		t.Errorf("expected the new key appended, got %v", got)
	}
}

// The mux options are identical on every call and would dominate the echoed
// command line, so they are elided from display only.
func TestEchoArgvElidesControlOptions(t *testing.T) {
	argv := []string{
		"ssh",
		"-o", "BatchMode=yes",
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=/tmp/deploy-ssh-1/%C",
		"-o", "ControlPersist=300",
		"ro", "readlink /run/current-system",
	}
	got := strings.Join(echoArgv(argv), " ")
	want := "ssh -o BatchMode=yes ro readlink /run/current-system"
	if got != want {
		t.Errorf("echoArgv = %q, want %q", got, want)
	}
}

func TestEchoArgvLeavesPlainArgvAlone(t *testing.T) {
	argv := []string{"ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "ro", "true"}
	if got := strings.Join(echoArgv(argv), " "); got != strings.Join(argv, " ") {
		t.Errorf("echoArgv changed a mux-free argv: %q", got)
	}
}
