package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Runner executes external commands. Production code uses ExecRunner; tests use
// a fake. All code that shells out must go through this interface so the
// state machine can be tested without real ssh/nixos-rebuild.
type Runner interface {
	Run(ctx context.Context, argv []string, opts RunOpts) RunResult
}

type RunOpts struct {
	// Env extends os.Environ() with these entries (KEY=VALUE).
	Env []string
	// Stream, if true, tees stdout/stderr to the process's stdout/stderr in
	// addition to capturing them. Used for nixos-rebuild build so the user
	// sees live progress on a multi-minute operation.
	Stream bool
}

type RunResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
	// TimedOut is true if the command was killed by the context deadline.
	TimedOut bool
	// Err is set for spawn failures or non-exit errors. Nil on normal exit
	// (even non-zero). TimedOut is reported separately.
	Err error
}

func (r RunResult) Failed() bool {
	return r.Err != nil || r.TimedOut || r.ExitCode != 0
}

type ExecRunner struct {
	// Quiet suppresses the "Running:" echo. Used by the precheck pass, whose
	// probes run concurrently and would otherwise interleave into noise.
	Quiet bool
	// Control is the ssh ControlMaster directory shared by every SSH call this
	// runner makes. Nil disables multiplexing.
	Control *SSHControl
}

// SSHControl satisfies sshControlled, which is how the SSH helpers find the
// control directory without taking it as a parameter.
func (r ExecRunner) SSHControl() *SSHControl { return r.Control }

func (r ExecRunner) Run(ctx context.Context, argv []string, opts RunOpts) RunResult {
	if !r.Quiet {
		fmt.Printf("  Running: %s\n", strings.Join(echoArgv(argv), " "))
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	if len(opts.Env) > 0 {
		cmd.Env = mergeEnv(os.Environ(), opts.Env)
	}
	var stdout, stderr bytes.Buffer
	if opts.Stream {
		cmd.Stdout = io.MultiWriter(&stdout, os.Stdout)
		cmd.Stderr = io.MultiWriter(&stderr, os.Stderr)
	} else {
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
	}
	err := cmd.Run()
	res := RunResult{
		Stdout: stdout.String(),
		Stderr: stderr.String(),
	}
	if ctx.Err() == context.DeadlineExceeded {
		res.TimedOut = true
		return res
	}
	if err != nil {
		var exitErr *exec.ExitError
		if asExit(err, &exitErr) {
			res.ExitCode = exitErr.ExitCode()
			return res
		}
		res.Err = err
		return res
	}
	return res
}

// asExit is a small wrapper around errors.As so the file doesn't need to import
// errors just for one call site.
func asExit(err error, target **exec.ExitError) bool {
	for cur := err; cur != nil; {
		if ee, ok := cur.(*exec.ExitError); ok {
			*target = ee
			return true
		}
		if unw, ok := cur.(interface{ Unwrap() error }); ok {
			cur = unw.Unwrap()
			continue
		}
		break
	}
	return false
}

// WithTimeout is a convenience for callers that want a per-call timeout
// without composing context themselves.
func WithTimeout(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}

// controlEchoOpts are the ssh options elided from the "Running:" echo. They are
// identical on every call and would otherwise dominate the width of each line.
var controlEchoOpts = []string{"ControlMaster=", "ControlPath=", "ControlPersist="}

// echoArgv is argv with the multiplexing options dropped, for display only.
func echoArgv(argv []string) []string {
	out := make([]string, 0, len(argv))
	for i := 0; i < len(argv); i++ {
		if argv[i] == "-o" && i+1 < len(argv) && hasAnyPrefix(argv[i+1], controlEchoOpts) {
			i++
			continue
		}
		out = append(out, argv[i])
	}
	return out
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// mergeEnv overlays KEY=VALUE entries onto base, replacing an existing KEY in
// place rather than appending a second entry for it. Duplicates are not merely
// untidy: which one wins depends on the consumer (glibc getenv takes the first,
// Python's os.environ the last), and NIX_SSHOPTS is read by both.
func mergeEnv(base, overrides []string) []string {
	out := append([]string(nil), base...)
	for _, kv := range overrides {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			out = append(out, kv)
			continue
		}
		key := kv[:eq+1]
		replaced := false
		for i, e := range out {
			if strings.HasPrefix(e, key) {
				out[i] = kv
				replaced = true
				break
			}
		}
		if !replaced {
			out = append(out, kv)
		}
	}
	return out
}
