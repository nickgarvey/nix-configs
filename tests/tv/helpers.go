// Helpers for driving guevenne (the TV box) and nelkir (the Pi wired to the
// TV's CEC bus) over ssh.
//
// Two rules shape everything here:
//
//   - CEC accepts messages it then ignores, so never assert on a transmit
//     result. Assert the TV's observed power state, or the ROUTING_CHANGE the
//     TV itself broadcasts.
//   - Opening Steam's menu is intermittent, so anything that drives the UI
//     retries rather than reporting a product failure on the first miss.
package tvtest

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const (
	guevenne = "guevenne"
	nelkir   = "nelkir"
)

// run executes a command on a host. Stdout is returned trimmed; stderr is
// folded into the error so a failure says what actually went wrong.
func run(host, cmd string) (string, error) {
	c := exec.Command("ssh",
		"-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
		"-o", "StrictHostKeyChecking=accept-new", host, cmd)
	var out, errb strings.Builder
	c.Stdout = &out
	c.Stderr = &errb
	err := c.Run()
	s := strings.TrimSpace(out.String())
	if err != nil {
		return s, fmt.Errorf("%s: %s: %w (stderr: %s)", host, cmd, err, strings.TrimSpace(errb.String()))
	}
	return s, nil
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// ---------------------------------------------------------------- TV power

// tvStatus asks the TV, via nelkir, what it thinks its power state is.
// "unknown" is normal for several seconds after any transition.
func tvStatus() string {
	out, err := run(guevenne, "tv status")
	if err != nil {
		return "unreachable"
	}
	return lastLine(out)
}

// tvSettled polls past the transitional "unknown".
func tvSettled(timeout time.Duration) string {
	deadline := time.Now().Add(timeout)
	s := "unknown"
	for time.Now().Before(deadline) {
		if s = tvStatus(); s != "unknown" {
			return s
		}
		time.Sleep(4 * time.Second)
	}
	return s
}

func waitTV(state string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if tvStatus() == state {
			return true
		}
		time.Sleep(4 * time.Second)
	}
	return false
}

// guevennePA reads the CEC physical address the TV assigned to guevenne's HDMI
// port out of the EDID served on that port, which is how the host discovers
// which input it is plugged into without anything being hardcoded.
func guevennePA() (string, error) {
	out, err := run(guevenne, `nix shell nixpkgs#edid-decode -c sh -c `+
		`"edid-decode /sys/class/drm/card1-HDMI-A-1/edid 2>/dev/null | `+
		`awk '/Source physical address/ {print \$NF}'"`)
	if err != nil {
		return "", err
	}
	pa := lastLine(out)
	if len(strings.Split(pa, ".")) != 4 {
		return "", fmt.Errorf("no physical address in EDID, got %q", pa)
	}
	return pa, nil
}

// -------------------------------------------------------------- CEC monitor

// cecMonitorStart begins capturing the CEC bus on nelkir. It needs root, and
// fails silently without it -- which once cost an afternoon of wrong theories.
func cecMonitorStart(file string, seconds int) error {
	_, err := run(nelkir, fmt.Sprintf(
		`sudo sh -c "nohup timeout %d cec-ctl -d /dev/cec0 --monitor > %s 2>&1 &"`,
		seconds, file))
	time.Sleep(3 * time.Second)
	return err
}

// routingAwk extracts the address named by the last routing message the TV
// itself sent.
//
// It matches only "Received from TV" blocks. nelkir transmits a
// SET_STREAM_PATH of its own whenever it is asked to switch inputs, so counting
// transmitted messages would let a test pass on the echo of its own command
// rather than on anything the TV did.
//
// Only SET_STREAM_PATH and ROUTING_CHANGE actually select an input, and the TV
// uses either one depending on the wake -- watching for ROUTING_CHANGE alone
// made a normal wake look like silence. ACTIVE_SOURCE is excluded: during a
// wake the TV broadcasts ACTIVE_SOURCE 0.0.0.0 claiming itself, which says
// nothing about which HDMI input ended up on screen.
const routingAwk = `awk '` +
	`/Received from TV.*(ROUTING_CHANGE|SET_STREAM_PATH)/ {f=1; next} ` +
	`f && /new-phys-addr:/ {v=$NF; f=0; next} ` +
	`f && /orig-phys-addr:/ {next} ` +
	`f && /phys-addr:/ {v=$NF; f=0; next} ` +
	`END {print v}'`

// cecLastRouting returns the physical address of the last input the TV said it
// routed to, or "" if it never announced one.
func cecLastRouting(file string) string {
	out, err := run(nelkir, fmt.Sprintf(`%s %s 2>/dev/null`, routingAwk, file))
	if err != nil {
		return ""
	}
	return lastLine(out)
}

// ------------------------------------------------------------------ Steam UI

type cdpEnvelope struct {
	Result struct {
		Result struct {
			Value string `json:"value"`
		} `json:"result"`
	} `json:"result"`
}

// cdpEval evaluates JavaScript in one of Steam's CEF targets and returns the
// string it produced. The expression is base64'd so it survives two layers of
// shell quoting intact.
func cdpEval(target, expr string) (string, error) {
	b64 := base64.StdEncoding.EncodeToString([]byte(expr))
	cmd := fmt.Sprintf(`
E=$(printf %%s '%s' | base64 -d)
WS=$(curl -s http://127.0.0.1:8080/json/list | nix shell nixpkgs#jq -c jq -r --arg t '%s' '[.[]|select(.title|contains($t))|.webSocketDebuggerUrl][0]')
if [ -z "$WS" ] || [ "$WS" = "null" ]; then echo "NOTARGET"; exit 1; fi
nix shell nixpkgs#jq -c jq -nc --arg e "$E" '{id:1,method:"Runtime.evaluate",params:{expression:$e,returnByValue:true,awaitPromise:true}}' | tr -d '\n' > /tmp/.tvtest-cdp
echo >> /tmp/.tvtest-cdp
nix shell nixpkgs#websocat -c websocat -n1 "$WS" < /tmp/.tvtest-cdp`, b64, target)

	out, err := run(guevenne, cmd)
	if err != nil {
		return "", err
	}
	var env cdpEnvelope
	if err := json.Unmarshal([]byte(lastLine(out)), &env); err != nil {
		return "", fmt.Errorf("unparseable CDP reply %q: %w", lastLine(out), err)
	}
	return env.Result.Result.Value, nil
}

// ydo sends input through uinput. xdotool does not work here: Steam ignores
// synthetic X events.
func ydo(script string) error {
	_, err := run(guevenne,
		`export YDOTOOL_SOCKET=/tmp/ydotool.sock DISPLAY=:0; `+
			`nix shell nixpkgs#ydotool -c sh -c '`+script+`'`)
	return err
}

func ensureYdotoold() error {
	if out, _ := run(guevenne, "ls /tmp/ydotool.sock 2>/dev/null"); strings.Contains(out, "ydotool.sock") {
		return nil
	}
	_, err := run(guevenne,
		`sudo modprobe uinput 2>/dev/null; `+
			`sudo sh -c "nix shell nixpkgs#ydotool -c setsid ydotoold --socket-path=/tmp/ydotool.sock --socket-own=1000:100 >/dev/null 2>&1 &"; `+
			`sleep 8; ls /tmp/ydotool.sock`)
	return err
}

// Steam's UI is split across several CEF targets: the Big Picture shell, a
// SharedJSContext, and separate popups for the main menu and quick access.
// Which one holds a given element is not obvious, so anything that reads the
// DOM says explicitly which target it means, and diagnostics sweep them all.
type cdpTarget struct {
	Title string `json:"title"`
	WS    string `json:"webSocketDebuggerUrl"`
}

func cdpTargets() ([]cdpTarget, error) {
	out, err := run(guevenne, `curl -s http://127.0.0.1:8080/json/list`)
	if err != nil {
		return nil, err
	}
	var ts []cdpTarget
	if err := json.Unmarshal([]byte(out), &ts); err != nil {
		return nil, fmt.Errorf("unparseable target list: %w", err)
	}
	return ts, nil
}

// cdpEvalAll evaluates the same expression in every CEF target and returns the
// results by target title.
//
// Steam spreads its UI across targets: the main menu lives in MainMenu_uid2
// while context menus render in the Big Picture target. Reading only one of
// them makes an open menu look like no menu at all, so state reads sweep them
// all -- in a single ssh round trip, because per-target ssh is far too slow to
// poll with.
func cdpEvalAll(expr string) (map[string]string, error) {
	b64 := base64.StdEncoding.EncodeToString([]byte(expr))
	script := `
E=$(printf %s '` + b64 + `' | base64 -d)
curl -s http://127.0.0.1:8080/json/list \
  | jq -r '.[] | select(.webSocketDebuggerUrl != null) | [.title, .webSocketDebuggerUrl] | @tsv' \
  | while IFS="$(printf '\t')" read -r title ws; do
      jq -nc --arg e "$E" '{id:1,method:"Runtime.evaluate",params:{expression:$e,returnByValue:true,awaitPromise:true}}' > /tmp/.tvtest-cdp-all
      R=$(websocat -n1 "$ws" < /tmp/.tvtest-cdp-all 2>/dev/null)
      printf '%s\t%s\n' "$title" "$R"
    done`
	out, err := run(guevenne, `nix shell nixpkgs#jq nixpkgs#websocat nixpkgs#curl -c bash -c `+shellQuote(script))
	if err != nil {
		return nil, err
	}
	res := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		title, body, ok := strings.Cut(line, "\t")
		if !ok || body == "" {
			continue
		}
		var env cdpEnvelope
		if err := json.Unmarshal([]byte(body), &env); err != nil {
			continue
		}
		res[title] = env.Result.Result.Value
	}
	return res, nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// setTVInput asks the TV to switch to a physical address. It goes through
// guevenne because nelkir's socket only accepts that host.
func setTVInput(pa string) error {
	_, err := run(guevenne, fmt.Sprintf(
		`exec 3<>/dev/tcp/nelkir/5555 && printf 'source %s\n' >&3 && timeout 5 head -1 <&3`, pa))
	return err
}

// piPhysAddr is nelkir's own input, used as a known-different starting input so
// that a wake back to guevenne must produce an observable routing change. The
// TV announces nothing when it wakes onto the input it was already showing, so
// without this the assertion has nothing to read.
const piPhysAddr = "3.0.0.0"

// waitLastRouting polls for the TV's routing announcement instead of sleeping a
// fixed interval and hoping. It returns "" if the TV stayed silent for the
// whole window, which callers still treat as a failure: silence means the input
// cannot be confirmed, not that it was correct.
func waitLastRouting(file string, timeout time.Duration) string {
	deadline := time.Now().Add(timeout)
	for {
		if pa := cecLastRouting(file); pa != "" {
			return pa
		}
		if time.Now().After(deadline) {
			return ""
		}
		time.Sleep(2 * time.Second)
	}
}
