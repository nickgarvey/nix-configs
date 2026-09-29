package main

import (
	"fmt"
	"sort"
	"sync"
	"time"
)

// buildPollInterval is how often the poller asks the store whether a host's
// toplevel has appeared. Cheap and local, so the interval is short enough that
// a finished build is dispatched promptly.
const buildPollInterval = 2 * time.Second

// OnFailure decides what happens to the hosts still queued when one fails.
type OnFailure string

const (
	OnFailureStop     OnFailure = "stop"
	OnFailureContinue OnFailure = "continue"
)

func ParseOnFailure(s string) (OnFailure, error) {
	switch OnFailure(s) {
	case OnFailureStop, OnFailureContinue:
		return OnFailure(s), nil
	}
	return "", fmt.Errorf("invalid --on-failure value %q (want stop|continue)", s)
}

// PipelineOpts are the knobs the pipeline takes from the CLI.
type PipelineOpts struct {
	CopyJobs  int
	OnFailure OnFailure
	Build     BuildOpts
}

// HostStatus is a host's terminal state in a pipeline run.
type HostStatus int

const (
	StatusDeployed HostStatus = iota
	StatusBuildFailed
	StatusCopyFailed
	StatusDeployFailed
	StatusCancelled
)

// HostResult is one host's outcome.
type HostResult struct {
	Host   Host
	Status HostStatus
}

func (s HostStatus) failed() bool { return s != StatusDeployed }

// RunPipeline moves every host through build → copy → activate, overlapping the
// stages across hosts while keeping activation strictly one at a time.
//
// Concurrency shape:
//
//	one `nix build` for the whole fleet   (nix schedules; the machine is bounded
//	                                       by nix's own max-jobs, not by us)
//	  ↓ poller: nix path-info, every 2s
//	copy workers, opts.CopyJobs of them   (network + sender-side compression)
//	  ↓
//	ONE activation worker                 (deploySafe: watchdog, activate, verify)
//
// Both channels are buffered to the host count, so no stage can block another
// and there is no ordering between them to deadlock on. A host reaches
// activation as soon as its own copy lands, regardless of what the other hosts
// are doing; Host.Order survives only as the tiebreak between hosts that become
// ready in the same poll tick, which keeps runs reproducible.
//
// extraDrvs are built-only hosts' derivations. They join the one fleet build and
// go no further; the caller checks whether they were built.
func RunPipeline(ctx *DeployContext, quiet Runner, todo []PrecheckResult, extraDrvs []string, opts PipelineOpts) []HostResult {
	if len(todo) == 0 {
		if len(extraDrvs) > 0 {
			say("\n[build] building %d host(s)...\n", len(extraDrvs))
			BuildAll(ctx.Runner, extraDrvs, opts.Build)
		}
		return nil
	}
	if opts.CopyJobs < 1 {
		opts.CopyJobs = 1
	}

	results := make([]HostResult, len(todo))
	index := make(map[string]int, len(todo))
	for i, p := range todo {
		results[i] = HostResult{Host: p.Host, Status: StatusDeployed}
		index[p.Host.Name] = i
	}
	setStatus := func(name string, s HostStatus) { results[index[name]].Status = s }

	copyCh := make(chan PrecheckResult, len(todo))
	actCh := make(chan PrecheckResult, len(todo))

	// Hosts already running the target closure have nothing to build or copy.
	// They still activate, because deploySafe's already-deployed path is what
	// notices an owed reboot from an earlier run.
	var needBuild []PrecheckResult
	for _, p := range todo {
		if p.Plan.UpToDate {
			actCh <- p
			continue
		}
		needBuild = append(needBuild, p)
	}

	drvs := make([]string, 0, len(needBuild)+len(extraDrvs))
	for _, p := range needBuild {
		drvs = append(drvs, p.Plan.DrvPath)
	}
	drvs = append(drvs, extraDrvs...)

	buildDone := make(chan struct{})
	go func() {
		defer close(buildDone)
		if len(drvs) == 0 {
			return
		}
		say("\n[build] building %d host(s)...\n", len(drvs))
		BuildAll(ctx.Runner, drvs, opts.Build)
	}()

	go pollBuilds(quiet, needBuild, buildDone, copyCh, setStatus)

	var wg sync.WaitGroup
	for i := 0; i < opts.CopyJobs; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range copyCh {
				start := time.Now()
				say("[copy] %s: starting\n", p.Host.Name)
				if !CopyClosure(quiet, p.Host, p.Plan.SystemPath) {
					setStatus(p.Host.Name, StatusCopyFailed)
					continue
				}
				say("[copy] ✓ %s in %s\n", p.Host.Name, time.Since(start).Round(time.Second))
				actCh <- p
			}
		}()
	}
	go func() { wg.Wait(); close(actCh) }()

	drainActivations(ctx, actCh, opts, setStatus)
	return results
}

// pollBuilds watches the store for each pending host's toplevel and dispatches
// it the moment it appears, rather than waiting for the whole build to finish.
//
// `nix build` reports nothing per-installable until it exits, so the store is
// the only per-host signal available. Because the expected path is pinned by
// the derivation resolved up front, a path appearing is unambiguous evidence
// that this host's build is done.
func pollBuilds(
	r Runner,
	pending []PrecheckResult,
	buildDone <-chan struct{},
	copyCh chan<- PrecheckResult,
	setStatus func(string, HostStatus),
) {
	defer close(copyCh)

	// Order-sorted so hosts that finish within the same tick dispatch
	// deterministically instead of in map order.
	left := append([]PrecheckResult(nil), pending...)
	sort.SliceStable(left, func(i, j int) bool { return left[i].Host.Order < left[j].Host.Order })

	sweep := func() {
		remaining := left[:0]
		for _, p := range left {
			if BuiltOK(r, p.Plan.SystemPath) {
				copyCh <- p
				continue
			}
			remaining = append(remaining, p)
		}
		left = remaining
	}

	for len(left) > 0 {
		select {
		case <-buildDone:
			// Final sweep: anything still missing was never built.
			sweep()
			for _, p := range left {
				say("[build] ✗ %s: not built\n", p.Host.Name)
				setStatus(p.Host.Name, StatusBuildFailed)
			}
			return
		case <-time.After(buildPollInterval):
			sweep()
		}
	}
}

// activate drains the ready queue with a single worker, so exactly one host is
// ever inside a watchdog window. Everything that depended on serialised
// activation therefore still holds: the k3s rolling gate (WaitForK8sReady runs
// inside deploySafe, so the next node cannot start until the previous one is
// Ready) and the reboot prompts, which read stdin.
func drainActivations(
	ctx *DeployContext,
	actCh <-chan PrecheckResult,
	opts PipelineOpts,
	setStatus func(string, HostStatus),
) {
	stopped := false
	for p := range actCh {
		if stopped {
			setStatus(p.Host.Name, StatusCancelled)
			continue
		}
		ok := Deploy(ctx, p.Host, ModeSafe, p.Plan)
		// Close this host's master now that nothing else will talk to it.
		dropSSHMaster(ctx.Runner, p.Host)
		if ok {
			continue
		}
		setStatus(p.Host.Name, StatusDeployFailed)
		// A k3s failure always stops the rest: the rolling deploy takes one
		// node down at a time assuming the others are up, so continuing after
		// one is broken risks quorum.
		if p.Host.InGroup("k3s") {
			say("\n✗ K3s rolling deploy failed at %s, stopping.\n", p.Host.Name)
			stopped = true
			continue
		}
		if opts.OnFailure == OnFailureStop {
			say("\n✗ %s failed; stopping (--on-failure=continue to keep going).\n", p.Host.Name)
			stopped = true
		}
	}
	// In-flight builds and copies are left to finish. They only populate nix
	// stores, so letting them complete costs time but nothing else, and it
	// keeps the shutdown path free of cancellation plumbing.
}
