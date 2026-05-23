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

type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, argv []string, opts RunOpts) RunResult {
	fmt.Printf("  Running: %s\n", strings.Join(argv, " "))
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	if len(opts.Env) > 0 {
		cmd.Env = append(os.Environ(), opts.Env...)
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
