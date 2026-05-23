package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

// CLIArgs are the parsed command-line arguments. Lifted out of main() so they
// can be tested independently.
type CLIArgs struct {
	Hosts  []string
	Mode   Mode
	Reboot RebootFlag
}

func parseArgs(argv []string) (CLIArgs, error) {
	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	hostsCSV := fs.String("hosts", "", "Comma-separated host names (default: all default hosts)")
	modeStr := fs.String("mode", "safe", "Deploy mode: safe|switch|boot")
	rebootStr := fs.String("reboot", "auto", "Reboot behavior: auto|never|always|ask")
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

	var hosts []string
	if *hostsCSV != "" {
		for _, h := range strings.Split(*hostsCSV, ",") {
			if t := strings.TrimSpace(h); t != "" {
				hosts = append(hosts, t)
			}
		}
	}
	return CLIArgs{Hosts: hosts, Mode: mode, Reboot: reboot}, nil
}

func main() {
	args, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}

	hosts, err := SelectHosts(AllHosts, args.Hosts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	runner := ExecRunner{}

	// Pre-flight: verify build host (tarrasque) is reachable. We always offload.
	fmt.Printf("Checking build host %s is reachable...\n", BuildHost)
	probeCtx, cancel := WithTimeout(15 * time.Second)
	probe := runner.Run(probeCtx, []string{
		"ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
		BuildHost, "true",
	}, RunOpts{})
	cancel()
	if probe.Failed() {
		fmt.Fprintf(os.Stderr, "✗ Build host %s unreachable. Aborting.\n", BuildHost)
		os.Exit(1)
	}
	fmt.Printf("✓ Build host %s reachable\n\n", BuildHost)

	names := make([]string, len(hosts))
	for i, h := range hosts {
		names[i] = h.Name
	}
	fmt.Printf("Hosts (%d): %v\n", len(hosts), names)
	fmt.Printf("Mode: %s, Reboot: %s\n", args.Mode, args.Reboot)

	var warnings []string
	ctx := &DeployContext{
		Runner:     runner,
		RebootFlag: args.Reboot,
		Prompter:   stdinPrompter,
		Warnings:   &warnings,
	}

	var failed []string
	for i, h := range hosts {
		if !Deploy(ctx, h, args.Mode) {
			failed = append(failed, h.Name)
			if h.InGroup("k3s") {
				fmt.Printf("\n✗ K3s rolling deploy failed at %s, stopping.\n", h.Name)
				break
			}
			// No prompt if this was the last host — nothing to continue to.
			if i == len(hosts)-1 {
				fmt.Printf("\n✗ %s failed.\n", h.Name)
				break
			}
			if !confirmContinue(h.Name) {
				break
			}
		}
	}

	fmt.Printf("\n%s\nSummary\n%s\n", strings.Repeat("=", 60), strings.Repeat("=", 60))
	if len(warnings) > 0 {
		fmt.Println("\nWarnings:")
		for _, w := range warnings {
			fmt.Printf("  ⚠ %s\n", w)
		}
	}
	if len(failed) > 0 {
		fmt.Printf("\nFailed hosts: %v\n", failed)
		os.Exit(1)
	}
	fmt.Println("\nAll hosts processed successfully!")
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

func confirmContinue(host string) bool {
	return stdinPrompter(fmt.Sprintf("\n✗ %s failed. Continue with remaining hosts? [y/N]: ", host))
}

