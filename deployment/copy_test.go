package main

import (
	"strings"
	"testing"
)

// Everything the pipeline copies was just built locally and carries no
// signature, and `nix copy` verifies signatures by default — a trusted
// connection does not change that. Without --no-check-sigs the transfer dies on
// the first locally-built path. Observed against dragonsreach:
//
//	error: cannot add path '/nix/store/...-home.garvey.sh.zone'
//	because it lacks a signature by a trusted key
func TestCopyArgvDoesNotCheckSignatures(t *testing.T) {
	joined := strings.Join(CopyArgv(AllHosts[1], "/nix/store/aaa"), " ")
	if !strings.Contains(joined, "--no-check-sigs") {
		t.Errorf("copy must not require signatures on locally-built paths: %s", joined)
	}
}

func TestCopyArgvTargetsRemoteStoreOverSSH(t *testing.T) {
	host := AllHosts[len(AllHosts)-1] // dragonsreach, reached by IP
	joined := strings.Join(CopyArgv(host, "/nix/store/aaa"), " ")

	for _, want := range []string{
		"nix copy",
		"--to ssh-ng://" + host.FQDN(),
		"--substitute-on-destination", // the old --use-substitutes
		"/nix/store/aaa",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("copy argv missing %q: %s", want, joined)
		}
	}
	// The remote daemon does the store write; nothing here escalates.
	if strings.Contains(joined, "sudo") {
		t.Errorf("copy must not use sudo: %s", joined)
	}
}
