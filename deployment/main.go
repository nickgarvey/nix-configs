package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

// CLIArgs are the parsed command-line arguments. Lifted out of main() so they
// can be tested independently.
type CLIArgs struct {
	Hosts     []string
	Mode      Mode
	Reboot    RebootFlag
	Force     bool
	Self      bool
	Build     bool
	CopyJobs  int
	MaxJobs   int
	Cores     int
	OnFailure OnFailure
}

// hostsFlagUsage renders the -hosts help text from AllHosts so the documented
// default set cannot drift from the one SelectHosts actually picks.
func hostsFlagUsage(all []Host) string {
	def := HostNames(all, func(h Host) bool { return h.Default })
	optIn := HostNames(all, func(h Host) bool { return !h.Default })
	s := "Comma-separated host names (default: " + strings.Join(def, ",") + ")"
	if len(optIn) > 0 {
		s += "; opt-in only: " + strings.Join(optIn, ",")
	}
	return s
}

func parseArgs(argv []string) (CLIArgs, error) {
	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	hostsCSV := fs.String("hosts", "", hostsFlagUsage(AllHosts))
	modeStr := fs.String("mode", "safe", "Deploy mode: safe|switch|boot")
	rebootStr := fs.String("reboot", "never", "Reboot behavior: never|auto|always|ask (-mode boot allows only never|always)")
	force := fs.Bool("force", false, "Skip safety pre-checks (e.g. active print on printer hosts)")
	self := fs.Bool("self", false, "Deploy to the host running this command (equivalent to -hosts $(hostname))")
	build := fs.Bool("build", false, "Only build configurations for the selected hosts; do not deploy or activate anything")
	copyJobs := fs.Int("copy-jobs", defaultCopyJobs, "Concurrent closure copies")
	maxJobs := fs.Int("max-jobs", 0, "Passed to nix build as --max-jobs (0 = leave it to nix.conf)")
	cores := fs.Int("cores", 0, "Passed to nix build as --cores (0 = leave it to nix.conf)")
	onFailure := fs.String("on-failure", string(OnFailureStop), "When a host fails: stop|continue")
	if err := fs.Parse(argv); err != nil {
		return CLIArgs{}, err
	}
	if fs.NArg() > 0 {
		return CLIArgs{}, fmt.Errorf("unexpected positional arguments: %v", fs.Args())
	}

	mode, err := ParseMode(*modeStr)
	if err != nil {
		return CLIArgs{}, err
	}
	reboot, err := ParseRebootFlag(*rebootStr)
	if err != nil {
		return CLIArgs{}, err
	}
	// boot mode stages a generation without activating it, so there is nothing
	// to compare against — the detection-dependent values are meaningless here.
	if mode == ModeBoot && (reboot == RebootFlagAuto || reboot == RebootFlagAsk) {
		return CLIArgs{}, fmt.Errorf(
			"--mode boot does not support --reboot %s (use never or always): "+
				"the staged generation is not activated, so there is nothing to detect", reboot)
	}

	var hosts []string
	if *hostsCSV != "" {
		for _, h := range strings.Split(*hostsCSV, ",") {
			if t := strings.TrimSpace(h); t != "" {
				hosts = append(hosts, t)
			}
		}
	}
	onFail, err := ParseOnFailure(*onFailure)
	if err != nil {
		return CLIArgs{}, err
	}
	if *copyJobs < 1 {
		return CLIArgs{}, fmt.Errorf("--copy-jobs must be at least 1, got %d", *copyJobs)
	}

	return CLIArgs{
		Hosts: hosts, Mode: mode, Reboot: reboot, Force: *force, Self: *self, Build: *build,
		CopyJobs: *copyJobs, MaxJobs: *maxJobs, Cores: *cores, OnFailure: onFail,
	}, nil
}

func main() { os.Exit(run()) }

// run is main's body. It returns an exit code rather than calling os.Exit so
// that the deferred SSH control cleanup actually runs — os.Exit skips defers,
// which would strand ControlMaster processes and their socket directory.
func run() int {
	args, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 2
	}

	if args.Self {
		hn, err := os.Hostname()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: --self: cannot determine hostname: %v\n", err)
			return 1
		}
		args.Hosts = append(args.Hosts, strings.SplitN(hn, ".", 2)[0])
	}

	hosts, err := SelectHosts(AllHosts, args.Hosts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 1
	}

	names := make([]string, len(hosts))
	for i, h := range hosts {
		names[i] = h.Name
	}

	// Build-only never touches a target, so it needs no control directory.
	if args.Build {
		fmt.Printf("Hosts (%d): %v\n", len(hosts), names)
		fmt.Println("Mode: build-only (no deploy)")
		runner := ExecRunner{}
		tops, err := ResolveToplevels(ExecRunner{Quiet: true}, hosts)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return 1
		}
		drvs := make([]string, 0, len(hosts))
		for _, h := range hosts {
			drvs = append(drvs, tops[h.Name].Drv)
		}
		BuildAll(runner, drvs, args.buildOpts())

		var failed []string
		for _, h := range hosts {
			if !BuiltOK(runner, tops[h.Name].Out) {
				failed = append(failed, h.Name)
			}
		}
		fmt.Printf("\n%s\nSummary\n%s\n", strings.Repeat("=", 60), strings.Repeat("=", 60))
		if len(failed) > 0 {
			fmt.Printf("\nFailed builds: %v\n", failed)
			return 1
		}
		fmt.Println("\nAll hosts built successfully!")
		return 0
	}

	// One ssh master per host for the whole run, instead of a fresh handshake
	// per remote command.
	ctl, err := NewSSHControl()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: cannot create ssh control directory: %v\n", err)
		return 1
	}
	runner := ExecRunner{Control: ctl}
	quiet := ExecRunner{Quiet: true, Control: ctl}
	defer ctl.Close(quiet)
	// The run blocks on stdin at the reboot and continue prompts, so Ctrl-C is
	// a realistic exit path and needs the same cleanup as a normal return.
	defer installSSHCleanup(ctl, quiet)()

	fmt.Printf("Hosts (%d): %v\n", len(hosts), names)
	fmt.Printf("Mode: %s, Reboot: %s\n", args.Mode, args.Reboot)

	// Precheck: resolve every toplevel in one eval, then probe all hosts at
	// once. Everything decided here — unreachable, mid-print, already up to
	// date — is decided before the first build instead of after it.
	fmt.Printf("\nResolving system paths for %d host(s) (single nix eval)...\n", len(hosts))
	paths, err := ResolveToplevels(quiet, hosts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 1
	}

	fmt.Printf("Probing %d host(s)...\n", len(hosts))
	pre := PrecheckAll(quiet, hosts, paths, args.Force)
	printPlan(pre)

	var warnings []string
	ctx := &DeployContext{
		Runner:     runner,
		RebootFlag: args.Reboot,
		Prompter:   stdinPrompter,
		Warnings:   &warnings,
	}

	var failed, skipped []string
	todo := make([]PrecheckResult, 0, len(pre))
	for _, p := range pre {
		switch {
		case p.Skip && p.Failed:
			failed = append(failed, p.Host.Name)
		case p.Skip:
			skipped = append(skipped, p.Host.Name)
		default:
			todo = append(todo, p)
		}
	}

	// A k3s node that failed the precheck aborts the run, the same way a k3s
	// node that fails mid-deploy does today. The rolling deploy takes one node
	// down at a time on the assumption that the other two are up; with one
	// already unreachable, rolling a second would drop etcd quorum.
	for _, p := range pre {
		if p.Skip && p.Failed && p.Host.InGroup("k3s") {
			fmt.Printf("\n✗ K3s node %s failed the precheck (%s) — not deploying anything.\n",
				p.Host.Name, p.Reason)
			fmt.Printf("  Rolling the remaining k3s nodes with one already down would risk quorum.\n")
			printSummary(warnings, skipped, failed)
			return 1
		}
	}

	if args.Mode == ModeSafe {
		// safe mode is pipelined: build, copy and activate overlap across
		// hosts, with activation kept to one host at a time.
		for _, r := range RunPipeline(ctx, quiet, todo, args.pipelineOpts()) {
			if r.Status.failed() {
				failed = append(failed, r.Host.Name)
			}
		}
	} else {
		// switch/boot are the debug paths: nixos-rebuild does its own build and
		// copy per host, so there is nothing to overlap.
		for _, p := range todo {
			ok := Deploy(ctx, p.Host, args.Mode, p.Plan)
			ctl.Drop(quiet, p.Host)
			if ok {
				continue
			}
			failed = append(failed, p.Host.Name)
			if p.Host.InGroup("k3s") {
				fmt.Printf("\n✗ K3s rolling deploy failed at %s, stopping.\n", p.Host.Name)
				break
			}
			if args.OnFailure == OnFailureStop {
				fmt.Printf("\n✗ %s failed; stopping (--on-failure=continue to keep going).\n", p.Host.Name)
				break
			}
		}
	}

	printSummary(warnings, skipped, failed)
	if len(failed) > 0 {
		return 1
	}
	fmt.Println("\nAll hosts processed successfully!")
	return 0
}

// installSSHCleanup closes the ssh control directory on SIGINT/SIGTERM, which
// no defer would catch. Returns a function that uninstalls the handler.
//
// Best effort: it races with any in-flight ssh, and ControlPersist is the
// backstop if it loses.
func installSSHCleanup(ctl *SSHControl, r Runner) func() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	go func() {
		if _, ok := <-ch; !ok {
			return
		}
		fmt.Println("\nInterrupted — closing ssh connections...")
		ctl.Close(r)
		os.Exit(130)
	}()
	return func() {
		signal.Stop(ch)
		close(ch)
	}
}

// printPlan reports what the precheck pass decided, in host order. The probes
// themselves run concurrently, so printing here rather than inside them is what
// keeps the output deterministic.
func printPlan(pre []PrecheckResult) {
	fmt.Printf("\n%s\nPlan\n%s\n", strings.Repeat("=", 60), strings.Repeat("=", 60))
	for _, p := range pre {
		switch {
		case p.Skip && p.Failed:
			fmt.Printf("  ✗ %-13s %s\n", p.Host.Name, p.Reason)
		case p.Skip:
			fmt.Printf("  ⊘ %-13s %s\n", p.Host.Name, p.Reason)
		case p.Plan.UpToDate:
			fmt.Printf("  = %-13s up to date (no build or copy)\n", p.Host.Name)
		default:
			fmt.Printf("  → %-13s deploy %s\n", p.Host.Name, p.Plan.SystemPath)
		}
	}
}

func printSummary(warnings, skipped, failed []string) {
	fmt.Printf("\n%s\nSummary\n%s\n", strings.Repeat("=", 60), strings.Repeat("=", 60))
	if len(warnings) > 0 {
		fmt.Println("\nWarnings:")
		for _, w := range warnings {
			fmt.Printf("  ⚠ %s\n", w)
		}
	}
	if len(skipped) > 0 {
		fmt.Printf("\nSkipped hosts: %v\n", skipped)
	}
	if len(failed) > 0 {
		fmt.Printf("\nFailed hosts: %v\n", failed)
	}
}

func stdinPrompter(prompt string) bool {
	fmt.Print(prompt)
	r := bufio.NewReader(os.Stdin)
	line, err := r.ReadString('\n')
	if err != nil {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(line), "y")
}


// defaultCopyJobs bounds concurrent closure transfers. Separate from the build
// bound because a copy is ssh plus sender-side compression, not a nix build job.
const defaultCopyJobs = 4

func (a CLIArgs) buildOpts() BuildOpts {
	return BuildOpts{
		MaxJobs: a.MaxJobs,
		Cores:   a.Cores,
		// A live build log and a stdin prompt cannot share a terminal, and
		// -reboot ask prompts mid-run.
		Stream: a.Reboot != RebootFlagAsk,
	}
}

func (a CLIArgs) pipelineOpts() PipelineOpts {
	return PipelineOpts{
		CopyJobs:  a.CopyJobs,
		OnFailure: a.OnFailure,
		Build:     a.buildOpts(),
	}
}
