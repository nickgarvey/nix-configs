package main

import (
	"context"
	"fmt"
	"strings"
)

// FakeRunner records command invocations and returns scripted responses. Used
// in tests; lives in a non-test file so other test files in the package can use
// it without import cycles.
type FakeRunner struct {
	// Calls is the ordered list of argv slices that have been invoked.
	Calls [][]string
	// Responses maps a command-match predicate to a result. The first matcher
	// that returns true is used. If no matcher matches, ZeroResult (exit 0,
	// empty output) is returned.
	Responses []FakeResponse
}

type FakeResponse struct {
	// Match returns true if this response should be used for the given argv.
	Match  func(argv []string) bool
	Result RunResult
}

func (f *FakeRunner) Run(_ context.Context, argv []string, _ RunOpts) RunResult {
	f.Calls = append(f.Calls, argv)
	for _, r := range f.Responses {
		if r.Match(argv) {
			return r.Result
		}
	}
	return RunResult{}
}

// MatchContains returns a Match function that matches any argv containing all
// of the given substrings (each substring matched against the joined argv).
func MatchContains(parts ...string) func([]string) bool {
	return func(argv []string) bool {
		joined := strings.Join(argv, " ")
		for _, p := range parts {
			if !strings.Contains(joined, p) {
				return false
			}
		}
		return true
	}
}

// CallsContaining returns calls whose joined argv contains all of the parts.
func (f *FakeRunner) CallsContaining(parts ...string) [][]string {
	var out [][]string
	for _, c := range f.Calls {
		joined := strings.Join(c, " ")
		match := true
		for _, p := range parts {
			if !strings.Contains(joined, p) {
				match = false
				break
			}
		}
		if match {
			out = append(out, c)
		}
	}
	return out
}

// CallString joins a recorded call for assertion error messages.
func CallString(argv []string) string {
	return fmt.Sprintf("%q", strings.Join(argv, " "))
}
