package main

import (
	"strings"
	"testing"
	"time"
)

func TestSSHArgv(t *testing.T) {
	host := Host{Name: "router", SSHAddress: "10.28.0.1"}
	argv := SSHArgv(host, "uname -r", 0)

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
	host := Host{Name: "talos", Domain: "home.arpa"}
	argv := SSHArgv(host, "true", 0)
	if argv[len(argv)-2] != "talos.home.arpa" {
		t.Errorf("argv host = %q, want talos.home.arpa", argv[len(argv)-2])
	}
}

func TestSSHArgvCustomConnectTimeout(t *testing.T) {
	host := Host{Name: "x"}
	argv := SSHArgv(host, "true", 5*time.Second)
	if !strings.Contains(strings.Join(argv, " "), "ConnectTimeout=5") {
		t.Errorf("expected ConnectTimeout=5, got %v", argv)
	}
}

func TestCheckSSHReachable(t *testing.T) {
	host := Host{Name: "talos", Domain: "home.arpa"}
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
