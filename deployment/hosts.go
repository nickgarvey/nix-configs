package main

import (
	"fmt"
	"sort"
	"strings"
)

type RebootPolicy int

const (
	RebootNever RebootPolicy = iota
	RebootPrompt
	RebootAuto
)

func (p RebootPolicy) String() string {
	switch p {
	case RebootNever:
		return "never"
	case RebootPrompt:
		return "prompt"
	case RebootAuto:
		return "auto"
	}
	return "unknown"
}

// ConnCheck names the per-host connectivity probes to run after activation.
type ConnCheck string

const (
	CheckSSH          ConnCheck = "ssh"
	CheckPingGateway  ConnCheck = "ping_gateway"
	CheckPing6Gateway ConnCheck = "ping6_gateway"
	CheckPingInternet ConnCheck = "ping_internet"
	CheckDNS          ConnCheck = "dns"
	CheckIPv6Tunnel   ConnCheck = "ipv6_tunnel"
	CheckIPv6Internet ConnCheck = "ipv6_internet"
)

type Host struct {
	Name           string
	FlakeName      string
	Domain         string
	SSHAddress     string // overrides FQDN if set (used by router)
	Order          int
	Reboot         RebootPolicy
	K8sHealthCheck bool
	Groups         []string
	Default        bool // false = opt-in only (framework13-laptop)
	ConnChecks     []ConnCheck
}

// BuildHost is always tarrasque per the rewrite scope (the --no-build-host
// escape hatch was dropped). aarch64 targets (skyforge) build via tarrasque's
// binfmt emulation. Centralised here so a future move would be one constant.
const BuildHost = "tarrasque"

func (h Host) FQDN() string {
	if h.SSHAddress != "" {
		return h.SSHAddress
	}
	if h.Domain == "" {
		return h.Name
	}
	return h.Name + "." + h.Domain
}

func (h Host) InGroup(g string) bool {
	for _, hg := range h.Groups {
		if hg == g {
			return true
		}
	}
	return false
}

// AllHosts is the source of truth for managed hosts. Keep entries sorted by
// Order so the deploy plan is read top-to-bottom.
var AllHosts = []Host{
	{
		Name: "k3s-lion", FlakeName: "k3s-lion", Domain: "home.arpa",
		Order: 10, Reboot: RebootAuto, K8sHealthCheck: true,
		Groups: []string{"k3s", "infra"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH, CheckPing6Gateway},
	},
	{
		Name: "k3s-dragon", FlakeName: "k3s-dragon", Domain: "home.arpa",
		Order: 11, Reboot: RebootAuto, K8sHealthCheck: true,
		Groups: []string{"k3s", "infra"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH, CheckPing6Gateway},
	},
	{
		Name: "k3s-goat", FlakeName: "k3s-goat", Domain: "home.arpa",
		Order: 12, Reboot: RebootAuto, K8sHealthCheck: true,
		Groups: []string{"k3s", "infra"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH, CheckPing6Gateway},
	},
	{
		Name: "framework-desktop", FlakeName: "framework-desktop", Domain: "home.arpa",
		Order: 20, Reboot: RebootPrompt,
		Groups: []string{"workstation"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH, CheckPingGateway},
	},
	{
		Name: "tarrasque", FlakeName: "tarrasque", Domain: "home.arpa",
		Order: 21, Reboot: RebootPrompt,
		Groups: []string{"workstation"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH, CheckPingGateway},
	},
	{
		Name: "aboleth", FlakeName: "aboleth", Domain: "home.arpa",
		Order: 30, Reboot: RebootPrompt,
		Groups: []string{"infra"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH, CheckPingGateway},
	},
	{
		Name: "framework13-laptop", FlakeName: "framework13-laptop",
		Order: 40, Reboot: RebootPrompt,
		Groups: []string{"workstation"}, Default: false,
		ConnChecks: []ConnCheck{CheckSSH},
	},
	{
		Name: "skyforge", FlakeName: "skyforge",
		Order: 50, Reboot: RebootPrompt,
		Groups: []string{"printer"}, Default: true,
		ConnChecks: []ConnCheck{CheckSSH},
	},
	{
		Name: "router", FlakeName: "router",
		SSHAddress: "10.28.0.1",
		Order:      99, Reboot: RebootNever,
		Groups:  []string{"infra", "router"},
		Default: true,
		ConnChecks: []ConnCheck{
			CheckSSH, CheckPingInternet, CheckDNS, CheckIPv6Tunnel, CheckIPv6Internet,
		},
	},
}

// SelectHosts filters AllHosts by the --hosts flag. Empty selector returns all
// Default hosts. Named hosts are returned even if !Default. Unknown names are
// an error. Output is sorted by Order; duplicates in the input are deduped.
func SelectHosts(all []Host, names []string) ([]Host, error) {
	var out []Host
	if len(names) == 0 {
		for _, h := range all {
			if h.Default {
				out = append(out, h)
			}
		}
	} else {
		seen := map[string]bool{}
		byName := map[string]Host{}
		for _, h := range all {
			byName[h.Name] = h
		}
		var unknown []string
		for _, n := range names {
			n = strings.TrimSpace(n)
			if n == "" || seen[n] {
				continue
			}
			seen[n] = true
			h, ok := byName[n]
			if !ok {
				unknown = append(unknown, n)
				continue
			}
			out = append(out, h)
		}
		if len(unknown) > 0 {
			known := make([]string, 0, len(all))
			for _, h := range all {
				known = append(known, h.Name)
			}
			return nil, fmt.Errorf("unknown host(s): %s (known: %s)",
				strings.Join(unknown, ", "), strings.Join(known, ", "))
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Order < out[j].Order })
	return out, nil
}
