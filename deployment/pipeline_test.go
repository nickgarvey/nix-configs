package main

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// pipeFake records what the pipeline ran, and tracks how many activations were
// in flight at once — the invariant the whole design rests on.
type pipeFake struct {
	mu sync.Mutex
	// built is the set of out paths path-info should report as present.
	built map[string]bool
	// copyFails and activateFails name hosts whose stage should fail.
	copyFails map[string]bool
	// copyDelay makes copies finish at different times, so a test can rely on
	// one host reaching activation while others are still copying.
	copyDelay     map[string]time.Duration
	activateFails map[string]bool
	// buildMakes is applied when `nix build` runs, so a test can decide which
	// hosts the build actually produced.
	buildMakes map[string]bool

	calls        []string
	activeNow    int
	activePeak   int
	activeOrder  []string
	copyOverlaps int
	copiesNow    int
}

func newPipeFake() *pipeFake {
	return &pipeFake{
		built:         map[string]bool{},
		copyFails:     map[string]bool{},
		copyDelay:     map[string]time.Duration{},
		activateFails: map[string]bool{},
		buildMakes:    map[string]bool{},
	}
}

// hostFromArgv identifies the target by matching whole argv elements. Substring
// matching on the joined command would be wrong: "ro" appears inside "profiles",
// "/nix/store/..." and most paths.
func hostFromArgv(argv []string, hosts []Host) string {
	for _, h := range hosts {
		fqdn := h.FQDN()
		for _, a := range argv {
			if a == fqdn || a == "ssh-ng://"+fqdn {
				return h.Name
			}
		}
	}
	return ""
}

func (f *pipeFake) Run(_ context.Context, argv []string, _ RunOpts) RunResult {
	joined := strings.Join(argv, " ")
	f.mu.Lock()
	f.calls = append(f.calls, joined)
	f.mu.Unlock()

	switch {
	case strings.Contains(joined, "nix build"):
		f.mu.Lock()
		for h := range f.buildMakes {
			f.built[h] = true
		}
		f.mu.Unlock()
		return RunResult{}

	case strings.Contains(joined, "path-info"):
		f.mu.Lock()
		defer f.mu.Unlock()
		for name := range f.built {
			if strings.Contains(joined, "/nix/store/"+name) && f.built[name] {
				return RunResult{}
			}
		}
		return RunResult{ExitCode: 1}

	case strings.Contains(joined, "nix copy"):
		name := hostFromArgv(argv, AllHosts)
		f.mu.Lock()
		f.copiesNow++
		d := f.copyDelay[name]
		f.mu.Unlock()
		if d == 0 {
			d = 2 * time.Millisecond
		}
		time.Sleep(d)
		f.mu.Lock()
		f.copiesNow--
		fail := f.copyFails[name]
		f.mu.Unlock()
		if fail {
			return RunResult{ExitCode: 1, Stderr: "copy refused"}
		}
		return RunResult{}

	// switch-to-configuration test brackets the activation critical section:
	// it is the first remote call deploySafe makes after arming the watchdog.
	case strings.Contains(joined, "switch-to-configuration test"):
		name := hostFromArgv(argv, AllHosts)
		f.mu.Lock()
		f.activeNow++
		if f.activeNow > f.activePeak {
			f.activePeak = f.activeNow
		}
		f.activeOrder = append(f.activeOrder, name)
		if f.copiesNow > 0 {
			f.copyOverlaps++
		}
		f.mu.Unlock()
		time.Sleep(2 * time.Millisecond)
		f.mu.Lock()
		f.activeNow--
		f.mu.Unlock()
		return RunResult{}

	// Failure is injected at the persist step rather than at activation:
	// a failed `switch-to-configuration test` on a host that is still
	// reachable is deliberately treated as success (activation can drop the
	// connection), so it is not a way to make a deploy fail.
	case strings.Contains(joined, "nix-env --profile"):
		f.mu.Lock()
		fail := f.activateFails[hostFromArgv(argv, AllHosts)]
		f.mu.Unlock()
		if fail {
			return RunResult{ExitCode: 1}
		}
		return RunResult{}

	case strings.Contains(joined, "echo ok"):
		return RunResult{Stdout: "ok\n"}
	case strings.Contains(joined, "profiles/system"):
		return RunResult{Stdout: "/nix/store/STALE\n"}
	case strings.Contains(joined, "readlink"):
		// Report the host's own planned path as active, so verifyActivePath
		// passes for whichever host is being deployed.
		name := hostFromArgv(argv, AllHosts)
		return RunResult{Stdout: "/nix/store/" + name + "\n"}
	case strings.Contains(joined, "uname -r"), strings.Contains(joined, "kernel-modules"):
		return RunResult{Stdout: "6.6.50\n"}
	case strings.Contains(joined, "kernel-params"):
		return RunResult{Stdout: "quiet\n"}
	}
	return RunResult{}
}

func (f *pipeFake) callsContaining(sub string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if strings.Contains(c, sub) {
			n++
		}
	}
	return n
}

// pipeHosts returns n hosts from AllHosts with k8s health disabled, so the
// tests exercise the pipeline rather than kubectl polling.
func pipeHosts(names ...string) []PrecheckResult {
	var out []PrecheckResult
	for _, n := range names {
		for _, h := range AllHosts {
			if h.Name != n {
				continue
			}
			h.K8sHealthCheck = false
			out = append(out, PrecheckResult{
				Host: h,
				Plan: Plan{
					SystemPath: "/nix/store/" + h.Name,
					DrvPath:    "/nix/store/" + h.Name + ".drv",
				},
			})
		}
	}
	return out
}

func pipeCtx(f *pipeFake) *DeployContext {
	return &DeployContext{
		Runner:     f,
		Sleeper:    func(time.Duration) {},
		Now:        func() time.Time { return time.Unix(1700000000, 0) },
		RebootFlag: RebootFlagNever,
	}
}

func runPipe(f *pipeFake, todo []PrecheckResult, opts PipelineOpts) []HostResult {
	return runPipeExtra(f, todo, nil, opts)
}

func runPipeExtra(f *pipeFake, todo []PrecheckResult, extraDrvs []string, opts PipelineOpts) []HostResult {
	if opts.CopyJobs == 0 {
		opts.CopyJobs = 4
	}
	if opts.OnFailure == "" {
		opts.OnFailure = OnFailureContinue
	}
	return RunPipeline(pipeCtx(f), f, todo, extraDrvs, opts)
}

func statusOf(res []HostResult, name string) HostStatus {
	for _, r := range res {
		if r.Host.Name == name {
			return r.Status
		}
	}
	return StatusCancelled
}

// The load-bearing invariant: however much builds and copies overlap, only one
// host is ever inside a watchdog window.
func TestPipelineActivationsNeverOverlap(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("wabbajack", "talos", "lydia", "skyforge")
	for _, p := range todo {
		f.buildMakes[p.Host.Name] = true
	}

	res := runPipe(f, todo, PipelineOpts{CopyJobs: 4})

	if f.activePeak != 1 {
		t.Errorf("activation must be serial, saw %d concurrent", f.activePeak)
	}
	for _, r := range res {
		if r.Status != StatusDeployed {
			t.Errorf("%s: status %v", r.Host.Name, r.Status)
		}
	}
	if len(f.activeOrder) != len(todo) {
		t.Errorf("want %d activations, got %v", len(todo), f.activeOrder)
	}
}

// Copies overlapping activation is the point of pipelining, not a bug. One host
// copies quickly while the others are held, so the overlap is deterministic
// rather than a race the test hopes to win.
func TestPipelineOverlapsCopyWithActivation(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("wabbajack", "talos", "lydia", "skyforge")
	for _, p := range todo {
		f.buildMakes[p.Host.Name] = true
		f.copyDelay[p.Host.Name] = 300 * time.Millisecond
	}
	f.copyDelay["wabbajack"] = time.Millisecond

	runPipe(f, todo, PipelineOpts{CopyJobs: 4})

	if f.copyOverlaps == 0 {
		t.Error("expected a copy to be in flight during an activation")
	}
}

// A host already running its target closure skips build and copy entirely, but
// still activates so an owed reboot is noticed.
func TestPipelineUpToDateHostSkipsBuildAndCopy(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("lydia")
	todo[0].Plan.UpToDate = true

	res := runPipe(f, todo, PipelineOpts{})

	if statusOf(res, "lydia") != StatusDeployed {
		t.Errorf("want deployed, got %v", statusOf(res, "lydia"))
	}
	if n := f.callsContaining("nix copy"); n != 0 {
		t.Errorf("an up-to-date host must not be copied, got %d copies", n)
	}
	if n := f.callsContaining("nix build"); n != 0 {
		t.Errorf("an up-to-date host must not be built, got %d builds", n)
	}
}

func TestPipelineUnbuiltHostIsFailedAndNeverCopied(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("lydia", "talos")
	f.buildMakes["lydia"] = true // talos never appears in the store

	res := runPipe(f, todo, PipelineOpts{})

	if got := statusOf(res, "talos"); got != StatusBuildFailed {
		t.Errorf("talos: want StatusBuildFailed, got %v", got)
	}
	if got := statusOf(res, "lydia"); got != StatusDeployed {
		t.Errorf("lydia: want StatusDeployed, got %v", got)
	}
	for _, c := range f.calls {
		if strings.Contains(c, "nix copy") && strings.Contains(c, "talos") {
			t.Errorf("a host that did not build must not be copied: %s", c)
		}
	}
}

func TestPipelineCopyFailureExcludesOnlyThatHost(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("lydia", "talos")
	for _, p := range todo {
		f.buildMakes[p.Host.Name] = true
	}
	f.copyFails["talos"] = true

	res := runPipe(f, todo, PipelineOpts{})

	if got := statusOf(res, "talos"); got != StatusCopyFailed {
		t.Errorf("talos: want StatusCopyFailed, got %v", got)
	}
	if got := statusOf(res, "lydia"); got != StatusDeployed {
		t.Errorf("lydia: want StatusDeployed, got %v", got)
	}
	for _, name := range f.activeOrder {
		if name == "talos" {
			t.Error("a host whose copy failed must not be activated")
		}
	}
}

func TestPipelineOnFailureStopHaltsRemainingActivations(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("wabbajack", "talos", "lydia")
	for _, p := range todo {
		f.buildMakes[p.Host.Name] = true
	}
	// wabbajack has the lowest Order, so the poller dispatches it first and it
	// reaches activation before the others — leaving something left to cancel.
	f.activateFails["wabbajack"] = true
	f.copyDelay["talos"] = 200 * time.Millisecond
	f.copyDelay["lydia"] = 200 * time.Millisecond

	res := runPipe(f, todo, PipelineOpts{CopyJobs: 4, OnFailure: OnFailureStop})

	if got := statusOf(res, "wabbajack"); got != StatusDeployFailed {
		t.Fatalf("wabbajack: want StatusDeployFailed, got %v", got)
	}
	cancelled := 0
	for _, r := range res {
		if r.Status == StatusCancelled {
			cancelled++
		}
	}
	if cancelled == 0 {
		t.Error("--on-failure=stop should cancel at least one queued host")
	}
}

func TestPipelineOnFailureContinueKeepsGoing(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("lydia", "talos", "wabbajack")
	for _, p := range todo {
		f.buildMakes[p.Host.Name] = true
	}
	f.activateFails["lydia"] = true

	res := runPipe(f, todo, PipelineOpts{CopyJobs: 1, OnFailure: OnFailureContinue})

	for _, r := range res {
		if r.Status == StatusCancelled {
			t.Errorf("%s cancelled under --on-failure=continue", r.Host.Name)
		}
	}
	if len(f.activeOrder) != len(todo) {
		t.Errorf("every host should have been activated, got %v", f.activeOrder)
	}
}

// A k3s failure stops the rest regardless of --on-failure: the rolling deploy
// assumes the other nodes are up.
func TestPipelineK3sFailureStopsEvenOnContinue(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("fus", "ro", "dah")
	for _, p := range todo {
		f.buildMakes[p.Host.Name] = true
	}
	f.activateFails["fus"] = true

	res := runPipe(f, todo, PipelineOpts{CopyJobs: 1, OnFailure: OnFailureContinue})

	if got := statusOf(res, "fus"); got != StatusDeployFailed {
		t.Fatalf("fus: want StatusDeployFailed, got %v", got)
	}
	cancelled := 0
	for _, r := range res {
		if r.Status == StatusCancelled {
			cancelled++
		}
	}
	if cancelled != 2 {
		t.Errorf("want the other 2 k3s nodes cancelled, got %d (%v)", cancelled, res)
	}
}

func TestPipelineEmptyTodoDoesNothing(t *testing.T) {
	f := newPipeFake()
	if res := runPipe(f, nil, PipelineOpts{}); res != nil {
		t.Errorf("want nil results, got %v", res)
	}
	if len(f.calls) != 0 {
		t.Errorf("want no calls, got %v", f.calls)
	}
}

// Build-only hosts join the one fleet build and are never copied or activated.
func TestPipelineExtraDrvsBuiltButNotDeployed(t *testing.T) {
	f := newPipeFake()
	todo := pipeHosts("lydia")
	f.buildMakes["lydia"] = true

	res := runPipeExtra(f, todo, []string{"/nix/store/guevenne.drv"}, PipelineOpts{})

	if got := statusOf(res, "lydia"); got != StatusDeployed {
		t.Errorf("lydia: want StatusDeployed, got %v", got)
	}
	if len(res) != 1 {
		t.Errorf("build-only hosts must not get a result, got %v", res)
	}
	if n := f.callsContaining("nix build"); n != 1 {
		t.Errorf("want one fleet build, got %d", n)
	}
	if n := f.callsContaining("/nix/store/guevenne.drv^out"); n != 1 {
		t.Errorf("build-only drv missing from the fleet build: %v", f.calls)
	}
	for _, c := range f.calls {
		if strings.Contains(c, "guevenne") && !strings.Contains(c, "nix build") {
			t.Errorf("a build-only host must not be touched after the build: %s", c)
		}
	}
}

// With every deploy host up to date there is nothing of theirs to build, but
// the build-only hosts still are.
func TestPipelineExtraDrvsBuiltWhenNothingToDeploy(t *testing.T) {
	f := newPipeFake()
	upToDate := pipeHosts("lydia")
	upToDate[0].Plan.UpToDate = true

	for _, todo := range [][]PrecheckResult{nil, upToDate} {
		f.calls = nil
		runPipeExtra(f, todo, []string{"/nix/store/guevenne.drv"}, PipelineOpts{})
		if n := f.callsContaining("/nix/store/guevenne.drv^out"); n != 1 {
			t.Errorf("todo=%d host(s): want the build-only drv built once, calls %v", len(todo), f.calls)
		}
	}
}

func TestParseOnFailure(t *testing.T) {
	for _, s := range []string{"stop", "continue"} {
		if _, err := ParseOnFailure(s); err != nil {
			t.Errorf("%s: unexpected error %v", s, err)
		}
	}
	if _, err := ParseOnFailure("maybe"); err == nil {
		t.Error("expected an error for an unknown value")
	}
}
