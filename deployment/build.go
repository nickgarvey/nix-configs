package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// resolveTimeout bounds the whole fan-out of per-host evals. They run at
	// the same time, so the fleet costs about as much as its slowest host
	// (~8s warm); the ceiling is for a cold eval.
	resolveTimeout = 15 * time.Minute
	// buildTimeout bounds the single build of every selected host.
	buildTimeout = 2 * time.Hour
	// pathInfoTimeout bounds a local store query.
	pathInfoTimeout = 30 * time.Second
)

// Toplevel is one host's system derivation and the output path it produces.
//
// Both halves come from the same eval so they cannot disagree. Building the
// derivation rather than re-evaluating the flake reference is what makes Out a
// promise: nothing between here and activation can change what gets built.
type Toplevel struct {
	Drv string `json:"drv"`
	Out string `json:"out"`
}

// ResolveToplevels returns each host's toplevel derivation and output path,
// keyed by Host.Name, using one `nix eval` per host run concurrently.
//
// Nix evaluation is single-threaded, so batching the fleet into one eval
// evaluates the hosts one after another and costs the sum of them (~31s for the
// ten default hosts). The hosts share almost nothing worth batching for: every
// nixosSystem instantiates its own pkgs, and skyforge's is a different
// architecture entirely. Fanning out one process per host costs the slowest
// host instead of the sum (~8s), for a fleet peak around 13GB of RSS.
//
// The result is keyed by Host.Name because each goroutine writes its own host's
// slot. Deriving the key from the store path instead would be unsound: path
// names do not reliably contain the host name (skyforge's toplevel is
// "nixos-system-skyforge-sd-card-..."), and mis-attributing a path here would
// mean copying one host's closure to another.
//
// Both halves come from the same eval, so they cannot disagree.
func ResolveToplevels(r Runner, hosts []Host) (map[string]Toplevel, error) {
	if len(hosts) == 0 {
		return map[string]Toplevel{}, nil
	}

	// One deadline for the whole fan-out: the evals run at the same time, so
	// the batch takes about as long as its slowest member.
	ctx, cancel := WithTimeout(resolveTimeout)
	defer cancel()

	type result struct {
		top Toplevel
		err error
	}
	results := make([]result, len(hosts))
	var wg sync.WaitGroup
	for i, h := range hosts {
		wg.Add(1)
		go func(i int, h Host) {
			defer wg.Done()
			// Distinct indices into a fixed-length slice: no lock needed.
			results[i].top, results[i].err = resolveToplevel(ctx, r, h)
		}(i, h)
	}
	wg.Wait()

	// Report every host that failed, not just the first: with the evals
	// running together, one broken config should not hide another.
	var errs []error
	out := make(map[string]Toplevel, len(hosts))
	for i, h := range hosts {
		if results[i].err != nil {
			errs = append(errs, results[i].err)
			continue
		}
		out[h.Name] = results[i].top
	}
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	return out, nil
}

// resolveToplevel evaluates one host's toplevel. Errors name the host, since
// the caller runs these concurrently and the argv alone would not say which
// failed.
func resolveToplevel(ctx context.Context, r Runner, h Host) (Toplevel, error) {
	res := r.Run(ctx, EvalArgv(h), RunOpts{})
	if res.Failed() {
		return Toplevel{}, fmt.Errorf("nix eval failed for %s: %s", h.Name, lastLines(res.Stderr, 20))
	}

	var t Toplevel
	if err := json.Unmarshal([]byte(res.Stdout), &t); err != nil {
		return Toplevel{}, fmt.Errorf("could not parse nix eval output for %s: %w", h.Name, err)
	}
	t.Drv, t.Out = strings.TrimSpace(t.Drv), strings.TrimSpace(t.Out)
	// A half-populated result would mean building one path and activating
	// another, so both halves must be there.
	if t.Drv == "" || t.Out == "" {
		return Toplevel{}, fmt.Errorf("nix eval returned no toplevel for %s (flake attr %q)",
			h.Name, h.FlakeName)
	}
	return t, nil
}

// EvalArgv renders one host's eval invocation. Split out so tests can assert on
// it without running anything.
//
// The eval cache is off: it cannot serve this query anyway (--apply bypasses it,
// and a dirty tree disables it), and the concurrent evals otherwise contend on
// its sqlite lock and log "database is busy" for every host.
func EvalArgv(h Host) []string {
	return []string{
		"nix", "eval", "--json",
		"--option", "eval-cache", "false",
		".#nixosConfigurations." + h.FlakeName + ".config.system.build.toplevel",
		"--apply", "t: { drv = t.drvPath; out = t.outPath; }",
	}
}

// BuildOpts carries the nix scheduling knobs. Zero means "leave it to nix.conf".
type BuildOpts struct {
	MaxJobs int
	Cores   int
	// Stream tees the build log live. Disabled when the run may prompt on
	// stdin, where interleaved build output makes the prompt unreadable.
	Stream bool
}

// BuildArgv renders the single build invocation. Split out so tests can assert
// on it without running anything.
//
// Every host goes into ONE nix invocation. That is what bounds the build
// machine: a single client is capped at nix's max-jobs no matter how many hosts
// are selected, whereas N concurrent `nixos-rebuild` processes would each get
// their own budget. It also means derivations shared between hosts are built
// once rather than once per host.
//
// The installables are the pre-resolved derivations, not flake references, so
// nix does not re-evaluate and cannot produce a path other than the one
// ResolveToplevels already committed to.
func BuildArgv(drvs []string, opts BuildOpts) []string {
	argv := []string{"nix", "build", "--no-link", "--print-build-logs"}
	// Without --keep-going one host's failure aborts every other host's build.
	// skyforge, built under binfmt emulation, is the likeliest to fail.
	argv = append(argv, "--keep-going")
	if opts.MaxJobs > 0 {
		argv = append(argv, "--max-jobs", strconv.Itoa(opts.MaxJobs))
	}
	if opts.Cores > 0 {
		argv = append(argv, "--cores", strconv.Itoa(opts.Cores))
	}
	for _, d := range drvs {
		argv = append(argv, d+"^out")
	}
	return argv
}

// BuildAll builds every given derivation in one nix invocation. The boolean
// reports whether nix exited clean; per-host success is decided by BuiltOK,
// because --keep-going means a non-zero exit can still have built most hosts.
func BuildAll(r Runner, drvs []string, opts BuildOpts) bool {
	if len(drvs) == 0 {
		return true
	}
	ctx, cancel := WithTimeout(buildTimeout)
	defer cancel()
	out := buildOut(opts)
	res := r.Run(ctx, BuildArgv(drvs, opts), RunOpts{Stream: opts.Stream, Out: out})
	if pw, ok := out.(*prefixWriter); ok {
		pw.Flush()
	}
	return !res.Failed()
}

// BuiltOK reports whether a store path is present and valid locally. This is
// how a host's build is attributed: `nix path-info` exits 0 for a realised path
// and 1 for one that is not there, which needs no log parsing and no assumption
// about the order of nix's output.
func BuiltOK(r Runner, outPath string) bool {
	if outPath == "" {
		return false
	}
	ctx, cancel := WithTimeout(pathInfoTimeout)
	defer cancel()
	return !r.Run(ctx, []string{"nix", "path-info", outPath}, RunOpts{}).Failed()
}

// lastLines returns the final n lines of s, which is where nix puts the actual
// error after its progress output.
func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
