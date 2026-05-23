package main

import "strings"

func trimmedEquals(s, want string) bool {
	return strings.TrimSpace(s) == want
}
