package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// SSH wraps the system `ssh` binary so we pick up ~/.ssh/config without
// reimplementing key/host parsing in Go.

const (
	sshConnectTimeout      = 10 * time.Second
	sshServerAliveInterval = 15 * time.Second
	defaultSSHTimeout      = 30 * time.Second
	// sshControlPersist bounds how long an idle master lingers. Bounded rather
	// than "yes" so a master nobody managed to close still reaps itself.
	sshControlPersist = 300 * time.Second
	// sshControlDropTimeout bounds `ssh -O exit`, which talks to the local mux
	// socket and so should answer immediately or not at all.
	sshControlDropTimeout = 5 * time.Second
)

// SSHControl owns the ControlMaster socket directory for one deploy process.
// One master per host replaces a fresh TCP+auth handshake per remote command.
//
// A nil *SSHControl means multiplexing is off: unit tests use runners that
// carry no control, and DEPLOY_NO_SSH_MUX=1 turns it off in production. Every
// method is nil-safe so callers never have to check.
type SSHControl struct{ Dir string }

// NewSSHControl creates the socket directory. Returns a nil control (not an
// error) when DEPLOY_NO_SSH_MUX is set.
//
// The directory is placed in /tmp explicitly rather than honouring $TMPDIR: a
// control socket is a unix socket, whose path is capped at ~107 bytes, and
// OpenSSH appends %C (40 hex chars) plus a 17-char suffix of its own. That
// leaves ~45 bytes for the directory, and `nix develop` — the normal way this
// tool is run — sets a $TMPDIR far longer than that.
func NewSSHControl() (*SSHControl, error) {
	if os.Getenv("DEPLOY_NO_SSH_MUX") != "" {
		return nil, nil
	}
	dir, err := os.MkdirTemp("/tmp", "deploy-ssh-")
	if err != nil {
		return nil, err
	}
	return &SSHControl{Dir: dir}, nil
}

func (c *SSHControl) enabled() bool { return c != nil && c.Dir != "" }

// pathPattern is the ControlPath as ssh expands it: %C hashes host, port and
// user, so every call for the same host lands on the same socket.
func (c *SSHControl) pathPattern() string { return filepath.Join(c.Dir, "%C") }

// Opts returns the ssh options that enable multiplexing, or nil when disabled.
func (c *SSHControl) Opts() []string {
	if !c.enabled() {
		return nil
	}
	return []string{
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + c.pathPattern(),
		"-o", "ControlPersist=" + strconv.Itoa(int(sshControlPersist.Seconds())),
	}
}

// sshNoMuxOpts forces a call to ignore the master and dial its own connection.
var sshNoMuxOpts = []string{"-o", "ControlMaster=no", "-o", "ControlPath=none"}

// directOpts suppresses multiplexing only when there is multiplexing to
// suppress, so a DEPLOY_NO_SSH_MUX run produces exactly the pre-mux argv.
func (c *SSHControl) directOpts() []string {
	if !c.enabled() {
		return nil
	}
	return sshNoMuxOpts
}

// NixSSHOpts renders the NIX_SSHOPTS entry that makes nixos-rebuild's own ssh
// calls attach to our master. nixos-rebuild builds `ssh <NIX_SSHOPTS> <its own
// defaults> host ...` and ssh honours the first value given for an option, so
// ours wins over the private control socket it would otherwise use.
//
// Any value the operator already exported is preserved ahead of ours, on the
// same first-wins principle: an explicit -i or jump host stays authoritative.
func (c *SSHControl) NixSSHOpts(existing string) []string {
	if !c.enabled() {
		return nil
	}
	joined := strings.Join(c.Opts(), " ")
	if existing = strings.TrimSpace(existing); existing != "" {
		joined = existing + " " + joined
	}
	return []string{"NIX_SSHOPTS=" + joined}
}

// Drop closes the master for one host. Best effort: a missing master is the
// normal case, not an error.
//
// This is how a connection drop is survived. A master whose TCP is gone still
// presents a live-looking socket, and a new session on it blocks past our
// timeouts instead of honouring ConnectTimeout, so the master has to be
// discarded explicitly wherever the target's network may have gone away.
func (c *SSHControl) Drop(r Runner, host Host) {
	if !c.enabled() {
		return
	}
	ctx, cancel := WithTimeout(sshControlDropTimeout)
	defer cancel()
	r.Run(ctx, []string{
		"ssh",
		"-o", "BatchMode=yes",
		"-o", "ControlPath=" + c.pathPattern(),
		"-O", "exit",
		host.FQDN(),
	}, RunOpts{})
}

// Close terminates every master and removes the directory. The masters are
// closed first: unlinking a socket does not kill the process holding it, it
// only orphans it until ControlPersist expires.
//
// Sockets are addressed by literal path here rather than by host, which catches
// masters for hosts the caller never tracked. With a fully expanded ControlPath
// the host argument is unused, hence "dummyhost".
func (c *SSHControl) Close(r Runner) {
	if !c.enabled() {
		return
	}
	socks, _ := filepath.Glob(filepath.Join(c.Dir, "*"))
	for _, s := range socks {
		ctx, cancel := WithTimeout(sshControlDropTimeout)
		r.Run(ctx, []string{
			"ssh",
			"-o", "BatchMode=yes",
			"-o", "ControlPath=" + s,
			"-O", "exit",
			"dummyhost",
		}, RunOpts{})
		cancel()
	}
	os.RemoveAll(c.Dir)
}

// sshControlled is implemented by runners that carry a control directory.
// Attaching the control to the runner rather than threading it through every
// SSH helper keeps the signatures of the call graph unchanged — and means test
// runners, which do not implement it, produce mux-free argv automatically.
type sshControlled interface{ SSHControl() *SSHControl }

func controlOf(r Runner) *SSHControl {
	if c, ok := r.(sshControlled); ok {
		return c.SSHControl()
	}
	return nil
}

// dropSSHMaster discards the master for host, if the runner has one.
func dropSSHMaster(r Runner, host Host) { controlOf(r).Drop(r, host) }

// nixSSHOptsFor renders the NIX_SSHOPTS env entry for nixos-rebuild calls.
func nixSSHOptsFor(r Runner) []string {
	return controlOf(r).NixSSHOpts(os.Getenv("NIX_SSHOPTS"))
}

// sshArgv builds an ssh argv with extra options spliced in. ServerAliveInterval
// ensures the client notices a dead control socket in ~15s rather than waiting
// for the OS TCP timeout — important during activation when networkd may
// briefly restart and drop the connection.
func sshArgv(extra []string, host Host, remoteCmd string, connectTimeout time.Duration) []string {
	if connectTimeout <= 0 {
		connectTimeout = sshConnectTimeout
	}
	argv := []string{
		"ssh",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=" + strconv.Itoa(int(connectTimeout.Seconds())),
		"-o", "ServerAliveInterval=" + strconv.Itoa(int(sshServerAliveInterval.Seconds())),
	}
	argv = append(argv, extra...)
	return append(argv, host.FQDN(), remoteCmd)
}

// SSHArgv builds the argv for a multiplexed ssh invocation.
func SSHArgv(c *SSHControl, host Host, remoteCmd string, connectTimeout time.Duration) []string {
	return sshArgv(c.Opts(), host, remoteCmd, connectTimeout)
}

// SSHArgvDirect builds the argv for an ssh invocation that dials its own
// connection, bypassing any master.
func SSHArgvDirect(c *SSHControl, host Host, remoteCmd string, connectTimeout time.Duration) []string {
	return sshArgv(c.directOpts(), host, remoteCmd, connectTimeout)
}

// transportFailed reports whether a result looks like the connection died
// rather than the remote command failing. 255 is ssh's own error exit, and a
// timeout is what a stale master produces once it stops answering.
func transportFailed(res RunResult) bool {
	return res.TimedOut || res.ExitCode == 255
}

// SSHRun executes a remote command over the host's shared master. On a
// transport failure it discards the master and dials again once, which is what
// makes an unexpected drop — a link flap, a networkd restart, the watchdog
// firing — cost a reconnect instead of a failed deploy step.
//
// Every command routed through here is idempotent, so the retry is always safe.
// Callers with a command that is not (see SSHRunOnce) must opt out.
func SSHRun(r Runner, host Host, remoteCmd string, timeout time.Duration) RunResult {
	res := SSHRunOnce(r, host, remoteCmd, timeout)
	if !transportFailed(res) || !controlOf(r).enabled() {
		return res
	}
	dropSSHMaster(r, host)
	return SSHRunOnce(r, host, remoteCmd, timeout)
}

// SSHRunOnce is SSHRun without the retry, for commands that must not run twice
// (arming the watchdog) or that do their own disconnect handling (activation).
func SSHRunOnce(r Runner, host Host, remoteCmd string, timeout time.Duration) RunResult {
	if timeout <= 0 {
		timeout = defaultSSHTimeout
	}
	ctx, cancel := WithTimeout(timeout)
	defer cancel()
	return r.Run(ctx, SSHArgv(controlOf(r), host, remoteCmd, sshConnectTimeout), RunOpts{})
}

// SSHRunDirect executes a remote command on its own connection, never the
// master. Used by the probes that exist precisely because the host's network is
// being disrupted: there a fresh handshake is the measurement, and reusing a
// socket would answer a question we did not ask.
func SSHRunDirect(r Runner, host Host, remoteCmd string, timeout time.Duration) RunResult {
	if timeout <= 0 {
		timeout = defaultSSHTimeout
	}
	ctx, cancel := WithTimeout(timeout)
	defer cancel()
	return r.Run(ctx, SSHArgvDirect(controlOf(r), host, remoteCmd, sshConnectTimeout), RunOpts{})
}

// CheckSSHReachable verifies SSH connectivity by running `echo ok`. Returns
// true iff the command succeeded and produced the expected output.
func CheckSSHReachable(r Runner, host Host) bool {
	return sshEchoOK(SSHRun(r, host, "echo ok", 15*time.Second))
}

// CheckSSHReachableDirect answers "is this host on the network right now?" with
// a connection of its own — after activation, during the reboot wait, and as
// the per-host SSH connectivity check.
func CheckSSHReachableDirect(r Runner, host Host) bool {
	return sshEchoOK(SSHRunDirect(r, host, "echo ok", 15*time.Second))
}

func sshEchoOK(res RunResult) bool {
	return !res.Failed() && trimmedEquals(res.Stdout, "ok")
}
