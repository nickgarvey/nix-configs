package main

import (
	"sort"
	"strings"
	"testing"
)

func TestHostOrdering(t *testing.T) {
	// AllHosts should be authored sorted by Order.
	for i := 1; i < len(AllHosts); i++ {
		if AllHosts[i-1].Order > AllHosts[i].Order {
			t.Fatalf("AllHosts not sorted by Order at index %d: %q(%d) > %q(%d)",
				i-1, AllHosts[i-1].Name, AllHosts[i-1].Order,
				AllHosts[i].Name, AllHosts[i].Order)
		}
	}
	// All k3s nodes must precede any non-k3s host.
	lastK3s := -1
	firstNonK3s := len(AllHosts)
	for i, h := range AllHosts {
		if h.InGroup("k3s") {
			lastK3s = i
		} else if i < firstNonK3s {
			firstNonK3s = i
		}
	}
	if lastK3s > firstNonK3s {
		t.Fatalf("k3s host at index %d follows non-k3s host at index %d", lastK3s, firstNonK3s)
	}
}

func TestHostFQDN(t *testing.T) {
	cases := []struct {
		h    Host
		want string
	}{
		{Host{Name: "router", SSHAddress: "10.28.0.1"}, "10.28.0.1"},
		{Host{Name: "talos", Domain: "home.arpa"}, "talos.home.arpa"},
		{Host{Name: "framework13-laptop"}, "framework13-laptop"},
	}
	for _, c := range cases {
		if got := c.h.FQDN(); got != c.want {
			t.Errorf("FQDN(%+v) = %q, want %q", c.h, got, c.want)
		}
	}
}

func TestSelectHosts(t *testing.T) {
	cases := []struct {
		name      string
		input     []string
		want      []string
		wantError bool
	}{
		{
			name:  "empty selects default hosts in order",
			input: nil,
			want: []string{
				"fus", "ro", "dah",
				"framework-desktop", "talos", "lydia",
				"skyforge", "router",
			},
		},
		{
			name:  "explicit single",
			input: []string{"router"},
			want:  []string{"router"},
		},
		{
			name:  "explicit selects non-default host (framework13-laptop)",
			input: []string{"framework13-laptop"},
			want:  []string{"framework13-laptop"},
		},
		{
			name:  "multi reorders by Order",
			input: []string{"router", "fus", "talos"},
			want:  []string{"fus", "talos", "router"},
		},
		{
			name:  "duplicates deduped",
			input: []string{"fus", "fus"},
			want:  []string{"fus"},
		},
		{
			name:      "unknown name errors",
			input:     []string{"nonexistent"},
			wantError: true,
		},
		{
			name:  "whitespace trimmed",
			input: []string{"  router  "},
			want:  []string{"router"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := SelectHosts(AllHosts, c.input)
			if c.wantError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			gotNames := make([]string, len(got))
			for i, h := range got {
				gotNames[i] = h.Name
			}
			if strings.Join(gotNames, ",") != strings.Join(c.want, ",") {
				t.Errorf("got %v, want %v", gotNames, c.want)
			}
		})
	}
}

func TestSelectHostsResultIsSorted(t *testing.T) {
	got, err := SelectHosts(AllHosts, []string{"router", "skyforge", "ro"})
	if err != nil {
		t.Fatal(err)
	}
	if !sort.SliceIsSorted(got, func(i, j int) bool { return got[i].Order < got[j].Order }) {
		t.Fatalf("result not sorted by Order: %v", got)
	}
}
