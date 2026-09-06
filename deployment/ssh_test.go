package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestSSHArgv(t *testing.T) {
	host := Host{Name: "dragonsreach", SSHAddress: "10.28.0.1"}
	argv := SSHArgv(nil, host, "uname -r", 0)

	joined := strings.Join(argv, " ")
	wantContains := []string{
		"ssh",
		"-o BatchMode=yes",
		"-o ConnectTimeout=10",
		"-o ServerAliveInterval=15",
		"10.28.0.1",
		"uname -r",
	}
	for _, w := range wantContains {
		if !strings.Contains(joined, w) {
			t.Errorf("argv missing %q: %s", w, joined)
		}
	}
	if argv[0] != "ssh" {
		t.Errorf("argv[0] = %q, want ssh", argv[0])
	}
	// Remote command must be the last argument (ssh expects it after the host).
	if argv[len(argv)-1] != "uname -r" {
		t.Errorf("remote cmd not last: %v", argv)
	}
}

func TestSSHArgvUsesFQDN(t *testing.T) {
	host := Host{Name: "talos"}
	argv := SSHArgv(nil, host, "true", 0)
	if argv[len(argv)-2] != "talos" {
		t.Errorf("argv host = %q, want talos", argv[len(argv)-2])
	}
}

func TestSSHArgvCustomConnectTimeout(t *testing.T) {
	host := Host{Name: "x"}
	argv := SSHArgv(nil, host, "true", 5*time.Second)
	if !strings.Contains(strings.Join(argv, " "), "ConnectTimeout=5") {
		t.Errorf("expected ConnectTimeout=5, got %v", argv)
	}
}

func TestCheckSSHReachable(t *testing.T) {
	host := Host{Name: "talos"}
	cases := []struct {
		name string
		resp RunResult
		want bool
	}{
		{"reachable", RunResult{Stdout: "ok\n"}, true},
		{"wrong output", RunResult{Stdout: "nope\n"}, false},
		{"nonzero exit", RunResult{Stdout: "ok\n", ExitCode: 1}, false},
		{"timeout", RunResult{TimedOut: true}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fake := &FakeRunner{
				Responses: []FakeResponse{
					{Match: func([]string) bool { return true }, Result: c.resp},
				},
			}
			got := CheckSSHReachable(fake, host)
			if got != c.want {
				t.Errorf("got %v, want %v", got, c.want)
			}
			if len(fake.Calls) != 1 || fake.Calls[0][0] != "ssh" {
				t.Errorf("expected one ssh call, got %v", fake.Calls)
			}
		})
	}
}

func TestSSHControlDisabled(t *testing.T) {
	var nilCtl *SSHControl
	if opts := nilCtl.Opts(); opts != nil {
		t.Errorf("nil control must produce no options, got %v", opts)
	}
	if opts := (&SSHControl{}).Opts(); opts != nil {
		t.Errorf("empty control must produce no options, got %v", opts)
	}
	// A disabled control must leave argv exactly as it was before multiplexing
	// existed, direct calls included — that is what DEPLOY_NO_SSH_MUX buys.
	host := Host{Name: "ro"}
	mux := strings.Join(SSHArgv(nil, host, "true", 0), " ")
	direct := strings.Join(SSHArgvDirect(nil, host, "true", 0), " ")
	if mux != direct {
		t.Errorf("disabled control: %q != %q", mux, direct)
	}
	if strings.Contains(mux, "Control") {
		t.Errorf("disabled control must emit no Control options: %s", mux)
	}
}

func TestSSHControlOpts(t *testing.T) {
	c := &SSHControl{Dir: "/tmp/deploy-ssh-test"}
	joined := strings.Join(c.Opts(), " ")
	for _, want := range []string{
		"ControlMaster=auto",
		"ControlPath=/tmp/deploy-ssh-test/%C",
		"ControlPersist=300",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("opts missing %q: %s", want, joined)
		}
	}
}

func TestSSHArgvSplicesControlBeforeHost(t *testing.T) {
	c := &SSHControl{Dir: "/tmp/deploy-ssh-test"}
	argv := SSHArgv(c, Host{Name: "talos"}, "uname -r", 0)
	if !strings.Contains(strings.Join(argv, " "), "ControlPath=/tmp/deploy-ssh-test/%C") {
		t.Errorf("expected control path in argv: %v", argv)
	}
	// ssh requires the host, then the command, as the final two arguments.
	if argv[len(argv)-2] != "talos" || argv[len(argv)-1] != "uname -r" {
		t.Errorf("control options must precede host and command: %v", argv)
	}
}

func TestSSHArgvDirectBypassesMaster(t *testing.T) {
	c := &SSHControl{Dir: "/tmp/deploy-ssh-test"}
	joined := strings.Join(SSHArgvDirect(c, Host{Name: "ro"}, "echo ok", 0), " ")
	for _, want := range []string{"ControlMaster=no", "ControlPath=none"} {
		if !strings.Contains(joined, want) {
			t.Errorf("direct argv missing %q: %s", want, joined)
		}
	}
	if strings.Contains(joined, "/tmp/deploy-ssh-test") {
		t.Errorf("direct argv must not reference the control dir: %s", joined)
	}
}

func TestNixSSHOpts(t *testing.T) {
	c := &SSHControl{Dir: "/tmp/deploy-ssh-test"}
	env := c.NixSSHOpts("")
	if len(env) != 1 || !strings.HasPrefix(env[0], "NIX_SSHOPTS=") {
		t.Fatalf("expected one NIX_SSHOPTS entry, got %v", env)
	}
	if !strings.Contains(env[0], "ControlPath=/tmp/deploy-ssh-test/%C") {
		t.Errorf("NIX_SSHOPTS missing control path: %s", env[0])
	}
	// A pre-existing value stays in front: ssh honours the first value given
	// for an option, so the operator's own settings remain authoritative.
	if env = c.NixSSHOpts("-i /key"); !strings.HasPrefix(env[0], "NIX_SSHOPTS=-i /key ") {
		t.Errorf("existing NIX_SSHOPTS must come first: %s", env[0])
	}
	var nilCtl *SSHControl
	if got := nilCtl.NixSSHOpts("-i /key"); got != nil {
		t.Errorf("disabled control must set no env, got %v", got)
	}
}

// sshSeqRunner returns `first` for the first remote command and `rest` for the
// ones after it, counting remote commands and `ssh -O exit` calls separately.
// It carries a control, so the SSH helpers treat it as multiplexed.
type sshSeqRunner struct {
	ctl   *SSHControl
	first RunResult
	rest  RunResult
	cmds  int
	exits int
}

func (s *sshSeqRunner) SSHControl() *SSHControl { return s.ctl }

func (s *sshSeqRunner) Run(_ context.Context, argv []string, _ RunOpts) RunResult {
	for _, a := range argv {
		if a == "-O" {
			s.exits++
			return RunResult{}
		}
	}
	s.cmds++
	if s.cmds == 1 {
		return s.first
	}
	return s.rest
}

// A dropped connection must cost a reconnect, not a failed deploy step: discard
// the master and dial again, exactly once.
func TestSSHRunRetriesOnceAfterTransportFailure(t *testing.T) {
	cases := []struct {
		name string
		bad  RunResult
	}{
		{"ssh connection error", RunResult{ExitCode: 255}},
		{"stale master times out", RunResult{TimedOut: true}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := &sshSeqRunner{
				ctl:   &SSHControl{Dir: "/tmp/deploy-ssh-test"},
				first: c.bad,
				rest:  RunResult{Stdout: "/nix/store/x\n"},
			}
			res := SSHRun(r, Host{Name: "ro"}, "readlink /run/current-system", time.Second)
			if res.Failed() {
				t.Errorf("expected the retry to succeed, got %+v", res)
			}
			if r.exits != 1 {
				t.Errorf("expected exactly one master drop, got %d", r.exits)
			}
			if r.cmds != 2 {
				t.Errorf("expected the command to run twice, got %d", r.cmds)
			}
		})
	}
}

// A command that failed on its own merits is reported as-is, not retried.
func TestSSHRunDoesNotRetryCommandFailure(t *testing.T) {
	r := &sshSeqRunner{
		ctl:   &SSHControl{Dir: "/tmp/deploy-ssh-test"},
		first: RunResult{ExitCode: 1},
		rest:  RunResult{},
	}
	if res := SSHRun(r, Host{Name: "ro"}, "false", time.Second); !res.Failed() {
		t.Error("expected failure")
	}
	if r.cmds != 1 || r.exits != 0 {
		t.Errorf("expected one command and no drop, got cmds=%d exits=%d", r.cmds, r.exits)
	}
}

// SSHRunOnce never retries: arming the watchdog must not run twice.
func TestSSHRunOnceDoesNotRetry(t *testing.T) {
	r := &sshSeqRunner{
		ctl:   &SSHControl{Dir: "/tmp/deploy-ssh-test"},
		first: RunResult{ExitCode: 255},
		rest:  RunResult{},
	}
	if res := SSHRunOnce(r, Host{Name: "ro"}, "sudo systemd-run --unit=x true", time.Second); !res.Failed() {
		t.Error("expected failure")
	}
	if r.cmds != 1 || r.exits != 0 {
		t.Errorf("expected one command and no drop, got cmds=%d exits=%d", r.cmds, r.exits)
	}
}

// Without a control there is no stale master to discard, so a single attempt
// remains a single attempt.
func TestSSHRunDoesNotRetryWithoutControl(t *testing.T) {
	fake := &FakeRunner{Responses: []FakeResponse{
		{Match: func([]string) bool { return true }, Result: RunResult{ExitCode: 255}},
	}}
	if res := SSHRun(fake, Host{Name: "ro"}, "true", time.Second); !res.Failed() {
		t.Error("expected failure")
	}
	if len(fake.Calls) != 1 {
		t.Errorf("expected one call without a control, got %d", len(fake.Calls))
	}
}
