package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// resolveTimeout bounds the single batched eval. Evaluating the whole fleet
// takes ~30s on a warm eval cache; the ceiling is for a cold one.
const resolveTimeout = 15 * time.Minute

// ResolveToplevels returns each host's system toplevel store path, keyed by
// Host.Name, using a single `nix eval`. One process means nixpkgs is evaluated
// once for the whole fleet rather than once per host.
//
// The result is keyed by the flake attribute name rather than derived from the
// order of the installables or from the store path's name. Both alternatives
// are unsound: argv order is not a documented property of nix's output, and
// store path names do not reliably contain the host name (skyforge's toplevel
// is "nixos-system-skyforge-sd-card-..."). Mis-attributing a path here would
// mean copying one host's closure to another, so it is worth the explicit key.
func ResolveToplevels(r Runner, hosts []Host) (map[string]string, error) {
	if len(hosts) == 0 {
		return map[string]string{}, nil
	}

	quoted := make([]string, 0, len(hosts))
	for _, h := range hosts {
		quoted = append(quoted, `"`+h.FlakeName+`"`)
	}
	apply := `cfgs: builtins.listToAttrs (map (n: { name = n; value = cfgs.${n}.config.system.build.toplevel.outPath; }) [ ` +
		strings.Join(quoted, " ") + ` ])`

	ctx, cancel := WithTimeout(resolveTimeout)
	defer cancel()
	res := r.Run(ctx, []string{
		"nix", "eval", "--json", ".#nixosConfigurations", "--apply", apply,
	}, RunOpts{})
	if res.Failed() {
		return nil, fmt.Errorf("nix eval failed: %s", lastLines(res.Stderr, 20))
	}

	var byFlakeName map[string]string
	if err := json.Unmarshal([]byte(res.Stdout), &byFlakeName); err != nil {
		return nil, fmt.Errorf("could not parse nix eval output: %w", err)
	}

	out := make(map[string]string, len(hosts))
	for _, h := range hosts {
		p := strings.TrimSpace(byFlakeName[h.FlakeName])
		if p == "" {
			return nil, fmt.Errorf("nix eval returned no toplevel path for %s (flake attr %q)",
				h.Name, h.FlakeName)
		}
		out[h.Name] = p
	}
	return out, nil
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
