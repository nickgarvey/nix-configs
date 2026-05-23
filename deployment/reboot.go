package main

import (
	"fmt"
	"strings"
	"time"
)

// RebootFlag is the value of the --reboot CLI flag.
type RebootFlag string

const (
	RebootFlagAuto   RebootFlag = "auto"
	RebootFlagNever  RebootFlag = "never"
	RebootFlagAlways RebootFlag = "always"
	RebootFlagAsk    RebootFlag = "ask"
)

func ParseRebootFlag(s string) (RebootFlag, error) {
	switch RebootFlag(s) {
	case RebootFlagAuto, RebootFlagNever, RebootFlagAlways, RebootFlagAsk:
		return RebootFlag(s), nil
	}
	return "", fmt.Errorf("invalid --reboot value %q (want auto|never|always|ask)", s)
}

// RebootAction is the resolved decision from RebootDecide.
type RebootAction int

const (
	RebootSkip   RebootAction = iota // no reboot
	RebootDo                         // reboot unconditionally
	RebootPromptUser                 // ask the user, then maybe reboot
)

// RebootDecide resolves the --reboot flag against the host's per-host policy
// and the detected kernel/params change. The full matrix:
//
//	flag       | NEVER       | PROMPT          | AUTO
//	-----------+-------------+-----------------+------------------
//	auto       | skip (warn) | prompt iff chg  | reboot iff chg
//	never      | skip        | skip            | skip
//	always     | skip (warn) | reboot          | reboot
//	ask        | skip        | prompt          | prompt
//
// NEVER hosts are a hard policy and never reboot regardless of the flag.
// For NEVER hosts under auto/always, the caller should surface a warning if
// kernelChanged is true.
func RebootDecide(flag RebootFlag, policy RebootPolicy, kernelChanged bool) RebootAction {
	if policy == RebootNever {
		return RebootSkip
	}
	switch flag {
	case RebootFlagNever:
		return RebootSkip
	case RebootFlagAlways:
		return RebootDo
	case RebootFlagAsk:
		return RebootPromptUser
	case RebootFlagAuto:
		if !kernelChanged {
			return RebootSkip
		}
		if policy == RebootPrompt {
			return RebootPromptUser
		}
		return RebootDo
	}
	return RebootSkip
}

// KernelChanged returns true if the running kernel differs from the kernel
// modules directory in /run/current-system, OR the booted kernel params
// differ (as a set) from the current-system params. Empty inputs (e.g. an SSH
// query failed) are treated as "unknown" and do not register as a change —
// both sides must be non-empty for a difference to count.
func KernelChanged(running, current string, bootedParams, currentParams string) bool {
	r := strings.TrimSpace(running)
	c := strings.TrimSpace(current)
	if r != "" && c != "" && r != c {
		return true
	}
	bp := paramSet(bootedParams)
	cp := paramSet(currentParams)
	if len(bp) > 0 && len(cp) > 0 && !setsEqual(bp, cp) {
		return true
	}
	return false
}

func paramSet(s string) map[string]struct{} {
	out := map[string]struct{}{}
	for _, f := range strings.Fields(s) {
		out[f] = struct{}{}
	}
	return out
}

func setsEqual(a, b map[string]struct{}) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if _, ok := b[k]; !ok {
			return false
		}
	}
	return true
}

// DetectKernelChange queries the host and returns whether a reboot is needed
// for the new kernel/params to take effect. Logs the diff to stdout for
// operator visibility.
func DetectKernelChange(r Runner, host Host) bool {
	running := SSHRun(r, host, "uname -r", 15*time.Second).Stdout
	current := SSHRun(r, host, "ls /run/current-system/kernel-modules/lib/modules/", 15*time.Second).Stdout
	bootedParams := SSHRun(r, host, "cat /run/booted-system/kernel-params", 15*time.Second).Stdout
	currentParams := SSHRun(r, host, "cat /run/current-system/kernel-params", 15*time.Second).Stdout

	rt := strings.TrimSpace(running)
	ct := strings.TrimSpace(current)
	if rt != "" && ct != "" && rt != ct {
		fmt.Printf("  Reboot needed: running kernel=%s != new kernel=%s\n", rt, ct)
	}
	bp := paramSet(bootedParams)
	cp := paramSet(currentParams)
	if len(bp) > 0 && len(cp) > 0 && !setsEqual(bp, cp) {
		var added, removed []string
		for k := range cp {
			if _, ok := bp[k]; !ok {
				added = append(added, k)
			}
		}
		for k := range bp {
			if _, ok := cp[k]; !ok {
				removed = append(removed, k)
			}
		}
		fmt.Println("  Reboot needed: kernel parameters changed")
		if len(added) > 0 {
			fmt.Printf("    Added: %v\n", added)
		}
		if len(removed) > 0 {
			fmt.Printf("    Removed: %v\n", removed)
		}
	}
	return KernelChanged(running, current, bootedParams, currentParams)
}
