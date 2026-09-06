package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	// resolveTimeout bounds the single batched eval. Evaluating the whole fleet
	// takes ~30s on a warm eval cache; the ceiling is for a cold one.
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
// keyed by Host.Name, using a single `nix eval`. One process means nixpkgs is
// evaluated once for the whole fleet rather than once per host.
//
// The result is keyed by the flake attribute name rather than derived from the
// order of the installables or from the store path's name. Both alternatives
// are unsound: argv order is not a documented property of nix's output, and
// store path names do not reliably contain the host name (skyforge's toplevel
// is "nixos-system-skyforge-sd-card-..."). Mis-attributing a path here would
// mean copying one host's closure to another, so it is worth the explicit key.
func ResolveToplevels(r Runner, hosts []Host) (map[string]Toplevel, error) {
	if len(hosts) == 0 {
		return map[string]Toplevel{}, nil
	}

	quoted := make([]string, 0, len(hosts))
	for _, h := range hosts {
		quoted = append(quoted, `"`+h.FlakeName+`"`)
	}
	apply := `cfgs: builtins.listToAttrs (map (n: { name = n; value = { ` +
		`drv = cfgs.${n}.config.system.build.toplevel.drvPath; ` +
		`out = cfgs.${n}.config.system.build.toplevel.outPath; }; }) [ ` +
		strings.Join(quoted, " ") + ` ])`

	ctx, cancel := WithTimeout(resolveTimeout)
	defer cancel()
	res := r.Run(ctx, []string{
		"nix", "eval", "--json", ".#nixosConfigurations", "--apply", apply,
	}, RunOpts{})
	if res.Failed() {
		return nil, fmt.Errorf("nix eval failed: %s", lastLines(res.Stderr, 20))
	}

	var byFlakeName map[string]Toplevel
	if err := json.Unmarshal([]byte(res.Stdout), &byFlakeName); err != nil {
		return nil, fmt.Errorf("could not parse nix eval output: %w", err)
	}

	out := make(map[string]Toplevel, len(hosts))
	for _, h := range hosts {
		t := byFlakeName[h.FlakeName]
		t.Drv, t.Out = strings.TrimSpace(t.Drv), strings.TrimSpace(t.Out)
		if t.Drv == "" || t.Out == "" {
			return nil, fmt.Errorf("nix eval returned no toplevel for %s (flake attr %q)",
				h.Name, h.FlakeName)
		}
		out[h.Name] = t
	}
	return out, nil
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
