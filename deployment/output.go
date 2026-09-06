package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sync"
)

// stdoutMu serialises writes to stdout. The build log streams while the
// activation stage prints, so the two must not tear each other's lines.
var stdoutMu sync.Mutex

// say prints one line to stdout under the shared lock. Used by the pipeline
// stages that print alongside the streaming build log.
func say(format string, a ...any) {
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	fmt.Printf(format, a...)
}

// prefixWriter tags each complete line with a prefix before forwarding it,
// holding a partial line until its newline arrives. Only the build log needs
// this: everything else in the pipeline emits whole lines of its own.
type prefixWriter struct {
	prefix string
	buf    []byte
}

func (w *prefixWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := w.buf[:i]
		w.buf = w.buf[i+1:]
		stdoutMu.Lock()
		os.Stdout.WriteString(w.prefix)
		os.Stdout.Write(line)
		os.Stdout.WriteString("\n")
		stdoutMu.Unlock()
	}
	return len(p), nil
}

// Flush emits a trailing partial line, if any.
func (w *prefixWriter) Flush() {
	if len(w.buf) == 0 {
		return
	}
	stdoutMu.Lock()
	os.Stdout.WriteString(w.prefix)
	os.Stdout.Write(w.buf)
	os.Stdout.WriteString("\n")
	stdoutMu.Unlock()
	w.buf = nil
}

// buildOut returns the writer for the build log, or nil to leave it to the
// runner's default.
func buildOut(opts BuildOpts) io.Writer {
	if !opts.Stream {
		return nil
	}
	return &prefixWriter{prefix: "[build] "}
}
