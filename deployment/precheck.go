package main

import (
	"fmt"
	"sync"
)

// precheckConcurrency bounds the parallel probe pass. These are short SSH and
// curl round trips, so the limit exists to avoid a thundering herd of ssh
// processes, not to protect the build machine.
const precheckConcurrency = 8

// Plan is what the precheck pass determined for a single host, and is the only
// thing Deploy needs to know about the work that preceded it.
type Plan struct {
	// SystemPath is the host's toplevel store path, resolved up front by
	// ResolveToplevels.
	SystemPath string
	// DrvPath is the derivation that produces SystemPath. The pipeline builds
	// this rather than the flake reference, so no re-evaluation can hand back a
	// path other than SystemPath.
	DrvPath string
	// UpToDate reports that the host already runs SystemPath and already boots
	// it, so building and copying the closure would be a no-op.
	UpToDate bool
}

// PrecheckResult is one host's outcome from the precheck pass.
type PrecheckResult struct {
	Host Host
	Plan Plan
	// Skip means the host is not deployed this run.
	Skip bool
	// Failed distinguishes a fault (unreachable) from a policy skip (printing).
	// Only meaningful when Skip is set.
	Failed bool
	// Reason explains Skip, for the plan table and the summary.
	Reason string
}

// PrecheckAll probes every host concurrently and decides what happens to it.
// Running this before any build means an unreachable host or an active print
// is discovered in seconds rather than after a multi-minute build, and hosts
// already running the target closure are dropped before they cost anything.
//
// Nothing here prints: results are reported by the caller in host order, so a
// concurrent pass still produces a deterministic, readable plan.
func PrecheckAll(r Runner, hosts []Host, tops map[string]Toplevel, force bool) []PrecheckResult {
	out := make([]PrecheckResult, len(hosts))
	sem := make(chan struct{}, precheckConcurrency)
	var wg sync.WaitGroup

	for i, h := range hosts {
		wg.Add(1)
		go func(i int, h Host) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			// Distinct indices into a fixed-length slice: no lock needed.
			out[i] = precheckHost(r, h, tops[h.Name], force)
		}(i, h)
	}
	wg.Wait()
	return out
}

func precheckHost(r Runner, host Host, top Toplevel, force bool) PrecheckResult {
	systemPath := top.Out
	res := PrecheckResult{Host: host, Plan: Plan{SystemPath: top.Out, DrvPath: top.Drv}}

	// Unreachable is a failure, not a skip: the same as today, just discovered
	// before the build instead of after it.
	if !CheckSSHReachable(r, host) {
		res.Skip, res.Failed = true, true
		res.Reason = "SSH unreachable"
		return res
	}

	if host.InGroup("printer") && !force {
		idle, state, ok := CheckPrinterIdle(r, host)
		if !ok {
			res.Skip = true
			res.Reason = "moonraker unreachable (--force to override)"
			return res
		}
		if !idle {
			res.Skip = true
			res.Reason = fmt.Sprintf("print active (state=%s), --force to override", state)
			return res
		}
	}

	res.Plan.UpToDate = hostAtPath(r, host, systemPath)
	return res
}
