package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// copyTimeout bounds a single closure transfer.
const copyTimeout = 60 * time.Minute

// CopyArgv renders the closure transfer. Split out so tests can assert on it.
//
// `nix copy` rather than `nixos-rebuild --target-host --sudo`: the remote
// nix-daemon performs the store write, so no sudo is involved.
//
// --no-check-sigs is required, not optional. Everything here was just built
// locally and so carries no signature, and `nix copy` asks the destination to
// verify signatures by default — it does not relax that just because the
// connection is trusted. Without the flag the transfer dies on the first
// locally-built path with "lacks a signature by a trusted key".
//
// The flag is a request, not a bypass: the destination only honours it for a
// connecting user in its trusted-users (modules/core/nixos-common.nix sets
// that fleet-wide). Both halves are needed.
//
// --substitute-on-destination is the equivalent of the old --use-substitutes:
// the target fetches what it can itself and only the remainder crosses the SSH
// connection.
func CopyArgv(host Host, path string) []string {
	return []string{
		"nix", "copy",
		"--to", "ssh-ng://" + host.FQDN(),
		"--substitute-on-destination",
		"--no-check-sigs",
		path,
	}
}

// copyEnv gives nix's own ssh the options it needs. nix spawns
// `ssh <NIX_SSHOPTS> ... <host>` and supplies none of these itself, so without
// them a copy to a host that has gone away blocks until the OS TCP timeout
// instead of honouring ConnectTimeout.
//
// The multiplexing options come last so that anything the operator exported —
// or SSHControl's own settings — keeps first-wins precedence, matching how
// SSHControl.NixSSHOpts composes them for nixos-rebuild.
func copyEnv(r Runner) []string {
	opts := []string{
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=" + fmt.Sprint(int(sshConnectTimeout.Seconds())),
		"-o", "ServerAliveInterval=" + fmt.Sprint(int(sshServerAliveInterval.Seconds())),
	}
	parts := []string{}
	if existing := strings.TrimSpace(os.Getenv("NIX_SSHOPTS")); existing != "" {
		parts = append(parts, existing)
	}
	parts = append(parts, strings.Join(opts, " "))
	if c := controlOf(r); c.enabled() {
		parts = append(parts, strings.Join(c.Opts(), " "))
	}
	return []string{"NIX_SSHOPTS=" + strings.Join(parts, " ")}
}

// CopyClosure transfers one host's system closure to it.
func CopyClosure(r Runner, host Host, path string) bool {
	ctx, cancel := WithTimeout(copyTimeout)
	defer cancel()
	res := r.Run(ctx, CopyArgv(host, path), RunOpts{Env: copyEnv(r)})
	if res.Failed() {
		say("[copy] ✗ %s: %s\n", host.Name, lastLines(res.Stderr, 3))
		return false
	}
	return true
}
