package main

import "testing"

func TestRebootDecide(t *testing.T) {
	type row struct {
		flag    RebootFlag
		policy  RebootPolicy
		changed bool
		want    RebootAction
	}
	// Full 4-flag x 3-policy x 2-changed matrix. NEVER hosts always skip.
	cases := []row{
		// auto
		{RebootFlagAuto, RebootNever, true, RebootSkip},
		{RebootFlagAuto, RebootNever, false, RebootSkip},
		{RebootFlagAuto, RebootPrompt, true, RebootPromptUser},
		{RebootFlagAuto, RebootPrompt, false, RebootSkip},
		{RebootFlagAuto, RebootAuto, true, RebootDo},
		{RebootFlagAuto, RebootAuto, false, RebootSkip},
		// never
		{RebootFlagNever, RebootNever, true, RebootSkip},
		{RebootFlagNever, RebootPrompt, true, RebootSkip},
		{RebootFlagNever, RebootAuto, true, RebootSkip},
		// always
		{RebootFlagAlways, RebootNever, true, RebootSkip},
		{RebootFlagAlways, RebootNever, false, RebootSkip},
		{RebootFlagAlways, RebootPrompt, true, RebootDo},
		{RebootFlagAlways, RebootPrompt, false, RebootDo},
		{RebootFlagAlways, RebootAuto, true, RebootDo},
		{RebootFlagAlways, RebootAuto, false, RebootDo},
		// ask
		{RebootFlagAsk, RebootNever, true, RebootSkip},
		{RebootFlagAsk, RebootPrompt, true, RebootPromptUser},
		{RebootFlagAsk, RebootPrompt, false, RebootPromptUser},
		{RebootFlagAsk, RebootAuto, true, RebootPromptUser},
		{RebootFlagAsk, RebootAuto, false, RebootPromptUser},
	}
	for _, c := range cases {
		got := RebootDecide(c.flag, c.policy, c.changed)
		if got != c.want {
			t.Errorf("RebootDecide(%s, %s, changed=%v) = %v, want %v",
				c.flag, c.policy, c.changed, got, c.want)
		}
	}
}

func TestParseRebootFlag(t *testing.T) {
	for _, ok := range []string{"auto", "never", "always", "ask"} {
		if _, err := ParseRebootFlag(ok); err != nil {
			t.Errorf("ParseRebootFlag(%q) errored: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "yes", "no", "AUTO", "force"} {
		if _, err := ParseRebootFlag(bad); err == nil {
			t.Errorf("ParseRebootFlag(%q) should error", bad)
		}
	}
}

func TestKernelChanged(t *testing.T) {
	cases := []struct {
		name        string
		running     string
		current     string
		bootedParams string
		currParams  string
		want        bool
	}{
		{"identical kernel and params", "6.6.50", "6.6.50", "quiet a=1", "a=1 quiet", false},
		{"kernel bumped", "6.6.50", "6.6.51", "quiet", "quiet", true},
		{"params reordered (set-equal)", "6.6.50", "6.6.50", "a=1 b=2", "b=2 a=1", false},
		{"params added", "6.6.50", "6.6.50", "a=1", "a=1 b=2", true},
		{"params removed", "6.6.50", "6.6.50", "a=1 b=2", "a=1", true},
		{"running empty = unknown, no change", "", "6.6.51", "a=1", "a=1", false},
		{"current empty = unknown, no change", "6.6.50", "", "a=1", "a=1", false},
		{"both param sources empty = no change", "6.6.50", "6.6.50", "", "", false},
		{"trailing whitespace tolerated", "6.6.50\n", "6.6.50\n", "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := KernelChanged(c.running, c.current, c.bootedParams, c.currParams)
			if got != c.want {
				t.Errorf("got %v, want %v", got, c.want)
			}
		})
	}
}
