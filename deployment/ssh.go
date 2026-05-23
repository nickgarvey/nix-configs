package main

import (
	"strconv"
	"time"
)

// SSH wraps the system `ssh` binary so we pick up ~/.ssh/config without
// reimplementing key/host parsing in Go.

const (
	sshConnectTimeout      = 10 * time.Second
	sshServerAliveInterval = 15 * time.Second
	defaultSSHTimeout      = 30 * time.Second
)

// SSHArgv builds the argv for an ssh invocation. ServerAliveInterval ensures
// the client notices a dead control socket in ~15s rather than waiting for
// the OS TCP timeout — important during activation when networkd may briefly
// restart and drop the connection.
func SSHArgv(host Host, remoteCmd string, connectTimeout time.Duration) []string {
	if connectTimeout <= 0 {
		connectTimeout = sshConnectTimeout
	}
	return []string{
		"ssh",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=" + strconv.Itoa(int(connectTimeout.Seconds())),
		"-o", "ServerAliveInterval=" + strconv.Itoa(int(sshServerAliveInterval.Seconds())),
		host.FQDN(),
		remoteCmd,
	}
}

// SSHRun executes a remote command via ssh and returns the result. Failure to
// connect or non-zero exit are surfaced via RunResult.Failed(); callers decide
// how to interpret them.
func SSHRun(r Runner, host Host, remoteCmd string, timeout time.Duration) RunResult {
	if timeout <= 0 {
		timeout = defaultSSHTimeout
	}
	ctx, cancel := WithTimeout(timeout)
	defer cancel()
	return r.Run(ctx, SSHArgv(host, remoteCmd, sshConnectTimeout), RunOpts{})
}

// CheckSSHReachable verifies SSH connectivity by running `echo ok`. Returns
// true iff the command succeeded and produced the expected output.
func CheckSSHReachable(r Runner, host Host) bool {
	res := SSHRun(r, host, "echo ok", 15*time.Second)
	return !res.Failed() && trimmedEquals(res.Stdout, "ok")
}
