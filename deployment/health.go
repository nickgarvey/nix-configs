package main

import (
	"fmt"
	"strings"
	"time"
)

const (
	k8sHealthRetries  = 12
	k8sHealthInterval = 10 * time.Second
	verifyRetries     = 3
	verifyRetryDelay  = 2 * time.Second
)

// WaitForK8sReady polls `kubectl get node <name>` for Ready=True up to
// k8sHealthRetries times with k8sHealthInterval between attempts.
// Sleeper is the wait function (injected for tests).
func WaitForK8sReady(r Runner, host Host, sleeper func(time.Duration)) bool {
	if sleeper == nil {
		sleeper = time.Sleep
	}
	fmt.Printf("  Waiting for node %s to become healthy...\n", host.Name)
	for i := 0; i < k8sHealthRetries; i++ {
		ctx, cancel := WithTimeout(15 * time.Second)
		res := r.Run(ctx, []string{
			"kubectl", "get", "node", host.Name,
			"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}",
		}, RunOpts{})
		cancel()
		status := strings.TrimSpace(res.Stdout)
		if !res.Failed() && status == "True" {
			fmt.Printf("  ✓ Node %s is Ready\n", host.Name)
			return true
		}
		detail := status
		if res.Failed() {
			detail = "kubectl error"
		}
		fmt.Printf("  Node %s status: %s (attempt %d/%d)\n",
			host.Name, detail, i+1, k8sHealthRetries)
		if i < k8sHealthRetries-1 {
			sleeper(k8sHealthInterval)
		}
	}
	fmt.Printf("  ✗ Node %s did not become healthy\n", host.Name)
	return false
}

// VerifyConnectivity runs the host's per-host ConnChecks list with retries
// (verifyRetries × verifyRetryDelay) to allow networkd to settle after the
// activation restart. All checks must pass on the same attempt to succeed.
func VerifyConnectivity(r Runner, host Host, sleeper func(time.Duration)) bool {
	if sleeper == nil {
		sleeper = time.Sleep
	}
	for attempt := 0; attempt < verifyRetries; attempt++ {
		allOK := true
		for _, c := range host.ConnChecks {
			label, ok := runConnCheck(r, host, c)
			if ok {
				fmt.Printf("    ✓ %s\n", label)
				continue
			}
			fmt.Printf("    ✗ %s: FAILED\n", label)
			allOK = false
			break
		}
		if allOK {
			return true
		}
		if attempt < verifyRetries-1 {
			fmt.Printf("  Connectivity check failed, retrying in %s (%d/%d)...\n",
				verifyRetryDelay, attempt+1, verifyRetries)
			sleeper(verifyRetryDelay)
		}
	}
	return false
}

func runConnCheck(r Runner, host Host, c ConnCheck) (string, bool) {
	switch c {
	case CheckSSH:
		return "SSH", CheckSSHReachable(r, host)
	case CheckPingGateway:
		return "Ping gateway", pingVia(r, host.FQDN(), "10.28.0.1", false)
	case CheckPing6Gateway:
		return "Ping6 gateway", pingVia(r, host.FQDN(), "2001:470:482f::1", true)
	case CheckPingInternet:
		return "Ping internet (1.1.1.1)", pingLocal(r, "1.1.1.1", false)
	case CheckDNS:
		return "DNS resolution", dnsLocal(r)
	case CheckIPv6Tunnel:
		return "IPv6 tunnel (HE)", pingVia(r, host.FQDN(), "2001:470:66:35::1", true)
	case CheckIPv6Internet:
		return "IPv6 internet", pingVia(r, host.FQDN(), "2001:4860:4860::8888", true)
	}
	return string(c), false
}

func pingVia(r Runner, viaHost, target string, v6 bool) bool {
	ctx, cancel := WithTimeout(25 * time.Second)
	defer cancel()
	pingCmd := "ping"
	flags := []string{"-c", "3", "-W", "5"}
	if v6 {
		flags = append([]string{"-6"}, flags...)
	}
	remote := pingCmd + " " + strings.Join(flags, " ") + " " + target
	res := r.Run(ctx, SSHArgv(Host{SSHAddress: viaHost}, remote, sshConnectTimeout), RunOpts{})
	return !res.Failed()
}

func pingLocal(r Runner, target string, v6 bool) bool {
	ctx, cancel := WithTimeout(25 * time.Second)
	defer cancel()
	argv := []string{"ping"}
	if v6 {
		argv = append(argv, "-6")
	}
	argv = append(argv, "-c", "3", "-W", "5", target)
	res := r.Run(ctx, argv, RunOpts{})
	return !res.Failed()
}

func dnsLocal(r Runner) bool {
	ctx, cancel := WithTimeout(15 * time.Second)
	defer cancel()
	res := r.Run(ctx, []string{"getent", "hosts", "google.com"}, RunOpts{})
	return !res.Failed()
}
