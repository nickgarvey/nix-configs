// Regression tests for the guevenne TV session: the gamescope/Steam session,
// nelkir's CEC control service, the injected "Turn Off TV" power-menu entry,
// and the power/input-routing behaviour those two produce together.
//
// Every test here exists because the corresponding behaviour broke once. See
// README.md for which bug each one covers.
//
// Tests that toggle TV power are guarded by -power (default on) because they
// take minutes and are visible in the living room.
package tvtest

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

var (
	powerTests = flag.Bool("power", true, "run tests that turn the TV on and off")

	// TV power state observed during preflight, restored after the run.
	initialTVState string
)

func TestMain(m *testing.M) {
	flag.Parse()

	if err := preflight(); err != nil {
		println("preflight failed:", err.Error())
		os.Exit(1)
	}

	code := m.Run()

	if err := restore(); err != nil {
		println("restore failed:", err.Error())
		if code == 0 {
			code = 1
		}
	}
	os.Exit(code)
}

// preflight establishes the starting state the whole suite assumes: both hosts
// reachable, both services up, an input daemon available, no menus open, and a
// known TV power state to return to.
func preflight() error {
	for _, h := range []string{guevenne, nelkir} {
		if _, err := run(h, "true"); err != nil {
			return err
		}
	}
	if err := ensureYdotoold(); err != nil {
		return err
	}
	// Steam's UI must be reachable over CDP, or every menu test is judging
	// nothing. A missing target means Steam dropped to desktop mode or died.
	if _, err := readMenu(); err != nil {
		return fmt.Errorf("Steam UI not reachable over CDP: %w", err)
	}
	// Establish the screen, not just the menus: tests navigate by label, and
	// the labels differ on a game page or the store.
	if err := requireHomeScreen(); err != nil {
		return fmt.Errorf("could not establish the home-screen baseline: %w", err)
	}
	if *powerTests {
		// Settle before recording, so we do not memorise "unknown".
		initialTVState = tvSettled(60 * time.Second)
		if initialTVState != "on" {
			if _, err := run(guevenne, "tv wake"); err != nil {
				return err
			}
			if !waitTV("on", 90*time.Second) {
				return fmt.Errorf("TV would not wake for the run (state %q)", tvStatus())
			}
		}
	}
	return nil
}

// restore puts the TV and the UI back where preflight found them, and says so
// out loud when it cannot -- being left with a TV in the wrong state and no
// warning is worse than a noisy failure.
func restore() error {
	if err := requireHomeScreen(); err != nil {
		return fmt.Errorf("could not restore the home screen: %w", err)
	}
	if !*powerTests || initialTVState == "" || initialTVState == "unknown" {
		return nil
	}
	if tvSettled(60*time.Second) == initialTVState {
		return nil
	}
	verb := "standby"
	if initialTVState == "on" {
		verb = "wake"
	}
	if _, err := run(guevenne, "tv "+verb); err != nil {
		return fmt.Errorf("TV left in the wrong state: tv %s failed: %w", verb, err)
	}
	if !waitTV(initialTVState, 90*time.Second) {
		return fmt.Errorf("TV left %q but the run started with it %q", tvStatus(), initialTVState)
	}
	return nil
}

// requireTV drives the TV to the given state before a test body runs, so the
// test starts from a known place rather than inheriting whatever the previous
// test left. It also asserts the drive actually worked.
func requireTV(t *testing.T, state string) {
	t.Helper()
	if tvStatus() == state {
		return
	}
	verb := "standby"
	if state == "on" {
		verb = "wake"
	}
	// The TV has been seen to accept CEC power commands, report OK on the
	// wire, and then neither change state nor respond to any further wake --
	// a stuck state that only a power cycle at the set clears. That is an
	// environment problem, not a regression, so say which one this is rather
	// than failing an assertion that implies the feature broke.
	for attempt := 1; attempt <= 2; attempt++ {
		if _, err := run(guevenne, "tv "+verb); err != nil {
			t.Fatalf("setup: tv %s failed: %v", verb, err)
		}
		if waitTV(state, 90*time.Second) {
			break
		}
		if attempt == 2 {
			t.Fatalf("setup: TV accepted `tv %s` twice but stayed %q (wanted %q). "+
				"The TV is not responding to CEC power control; power-cycle it at the set "+
				"before trusting any power result from this run.", verb, tvStatus(), state)
		}
	}
	// Let the TV's CEC stack quiesce; it reports state before it means it.
	time.Sleep(10 * time.Second)
}

// ------------------------------------------------------------------ session

func TestGamescopeSessionRunning(t *testing.T) {
	out, err := run(guevenne, "pgrep -a gamescope | head -3")
	if err != nil || out == "" {
		t.Fatalf("no gamescope process: %v (%q)", err, out)
	}
	if !strings.Contains(out, "--prefer-output") {
		t.Errorf("gamescope not started with the TV output pin: %q", out)
	}
}

// Steam's web helper needs its own Xwayland or QtWebEngine children land in the
// game's namespace and die.
func TestTwoXwaylandServers(t *testing.T) {
	out, _ := run(guevenne, "pgrep -c Xwayland")
	if lastLine(out) != "2" {
		t.Errorf("want 2 Xwayland servers, got %q", lastLine(out))
	}
}

func TestSteamRunning(t *testing.T) {
	if out, err := run(guevenne, "pgrep -f 'steam.*-tenfoot' | head -1"); err != nil || out == "" {
		t.Fatalf("Steam Big Picture not running: %v (%q)", err, out)
	}
}

// The broken internal panel must stay dark; the TV must be the only output.
func TestOnlyHDMIOutputEnabled(t *testing.T) {
	hdmi, _ := run(guevenne, "cat /sys/class/drm/card*-HDMI-A-1/status 2>/dev/null | head -1")
	if lastLine(hdmi) != "connected" {
		t.Errorf("HDMI-A-1 status = %q, want connected", lastLine(hdmi))
	}
	edp, _ := run(guevenne, "cat /sys/class/drm/card*-eDP-1/enabled 2>/dev/null | head -1")
	if s := lastLine(edp); s == "enabled" {
		t.Errorf("broken internal panel eDP-1 is enabled")
	}
}

func TestAudioRoutesToTV(t *testing.T) {
	out, err := run(guevenne, "wpctl status 2>/dev/null | grep -A5 Sinks | grep '\\*'")
	if err != nil {
		t.Fatalf("wpctl status failed: %v", err)
	}
	if !strings.Contains(strings.ToLower(out), "hdmi") {
		t.Errorf("default sink is not HDMI: %q", lastLine(out))
	}
}

// --------------------------------------------------------------- cec service

func TestCECSocketListening(t *testing.T) {
	out, _ := run(nelkir, "systemctl is-active cec-control.socket")
	if lastLine(out) != "active" {
		t.Errorf("cec-control.socket is %q, want active", lastLine(out))
	}
}

func TestCECAudioGuardActive(t *testing.T) {
	out, _ := run(nelkir, "systemctl is-active cec-audio-guard.service")
	if lastLine(out) != "active" {
		t.Errorf("cec-audio-guard is %q, want active", lastLine(out))
	}
}

// The service is unauthenticated on the LAN; only guevenne may drive it.
func TestCECRejectsUnknownSource(t *testing.T) {
	out, _ := run(nelkir, `exec 3<>/dev/tcp/127.0.0.1/5555 && echo status >&3 && timeout 5 head -1 <&3`)
	if got := lastLine(out); !strings.HasPrefix(got, "ERR") {
		t.Errorf("localhost was not refused, got %q", got)
	}
}

func TestCECStatusVerb(t *testing.T) {
	out, err := run(guevenne, "tv status")
	if err != nil {
		t.Fatalf("tv status failed: %v", err)
	}
	switch lastLine(out) {
	case "on", "standby", "unknown":
	default:
		t.Errorf("unexpected status %q", lastLine(out))
	}
}

func TestCECRejectsBadVerb(t *testing.T) {
	out, _ := run(guevenne, `exec 3<>/dev/tcp/nelkir/5555 && echo bogusverb >&3 && timeout 5 head -1 <&3`)
	if !strings.Contains(lastLine(out), "ERR") {
		t.Errorf("bad verb was not refused, got %q", lastLine(out))
	}
}

// Which HDMI port guevenne occupies is discovered from the EDID, never
// hardcoded, so re-cabling the TV does not silently break input switching.
func TestPhysicalAddressFromEDID(t *testing.T) {
	pa, err := guevennePA()
	if err != nil {
		t.Fatalf("could not read physical address: %v", err)
	}
	if pa == "0.0.0.0" || pa == "f.f.f.f" {
		t.Errorf("implausible physical address %q", pa)
	}
	t.Logf("guevenne is on physical address %s", pa)
}

// ---------------------------------------------------------------- steam menu

func TestMenuInjectorRunning(t *testing.T) {
	out, _ := run(guevenne, "systemctl --user is-active steam-tv-menu")
	if lastLine(out) != "active" {
		t.Errorf("steam-tv-menu is %q, want active", lastLine(out))
	}
}

// Scoped to the service's current invocation rather than a fixed number of
// journal lines: every menu activation logs three lines, so a line-count window
// scrolls the connection message away precisely when the suite is exercising
// the feature hardest.
func TestMenuInjectorConnected(t *testing.T) {
	since, err := run(guevenne, "systemctl --user show steam-tv-menu -p ActiveEnterTimestamp --value")
	if err != nil || since == "" {
		t.Fatalf("could not read the injector's start time: %v (%q)", err, since)
	}
	out, err := run(guevenne, fmt.Sprintf(
		"journalctl --user -u steam-tv-menu --since '%s' --no-pager", since))
	if err != nil {
		t.Fatalf("could not read the injector journal: %v", err)
	}
	if !strings.Contains(out, "injected") && !strings.Contains(out, "connected") {
		t.Errorf("injector has not reported a connection since it started at %s:\n%s", since, out)
	}
}

// menuTest opens the Power menu, hands its state to fn, and always closes the
// menu afterwards -- an open menu would poison every later test.
func menuTest(t *testing.T, fn func(m menuState)) {
	t.Helper()
	// Assert the screen, not just the menus, at both ends: these tests
	// navigate by label, and the labels only mean what we expect on home.
	if err := requireHomeScreen(); err != nil {
		t.Fatalf("setup: %v", err)
	}
	t.Cleanup(func() {
		if err := requireHomeScreen(); err != nil {
			t.Errorf("teardown: %v", err)
		}
	})
	m, err := openPowerMenu()
	if err != nil {
		t.Skipf("could not open the power menu, cannot judge its contents: %v", err)
	}
	t.Logf("opened: %s", m)
	fn(m)
}

// One menu open, three assertions. Opening the Power menu costs ~20s, and
// these all judge the same menuState, so they run as subtests of a single open
// rather than paying that cost three times.
func TestPowerMenu(t *testing.T) {
	menuTest(t, func(m menuState) {
		t.Run("has Turn Off TV", func(t *testing.T) {
			if !m.has("Turn Off TV") {
				t.Errorf("no %q row; %s", "Turn Off TV", m)
			}
		})
		// The entry works by relabelling "Switch to Desktop", a row Steam already
		// registers for controller focus. The original label reappearing means the
		// injection stopped applying -- and a controller press would then hit the
		// real "Switch to Desktop", which black-screens the TV.
		t.Run("Switch to Desktop replaced", func(t *testing.T) {
			if m.has("Switch to Desktop") {
				t.Errorf("original row is back; injection is not applying: %s", m)
			}
		})
		// The controller only reaches rows Steam itself focuses, which is why the
		// row is hijacked rather than appended.
		t.Run("row is focusable", func(t *testing.T) {
			if err := stepToLabel("Turn Off TV", keyDown, len(m.Rows)+2); err != nil {
				t.Errorf("controller navigation cannot reach the row: %v", err)
			}
		})
	})
}

// ----------------------------------------------------------- power behaviour

// cec-audio-guard used to reassert audio routing ~20s after standby, which
// woke the TV straight back up.
func TestStandbyStaysOff(t *testing.T) {
	if !*powerTests {
		t.Skip("-power=false")
	}
	requireTV(t, "on")
	t.Cleanup(func() { restoreTVOn(t) })

	if _, err := run(guevenne, "tv standby"); err != nil {
		t.Fatalf("tv standby failed: %v", err)
	}
	if !waitTV("standby", 60*time.Second) {
		t.Fatalf("TV did not turn off (state %q)", tvStatus())
	}
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(10 * time.Second)
		if s := tvStatus(); s == "on" {
			t.Fatalf("TV woke itself back up %v after standby", 60*time.Second-time.Until(deadline))
		}
	}
}

// The reported regression: choosing "Turn Off TV" turned the TV off but left it
// routed to the Pi, so the next wake showed the wrong input. Drive a full
// cycle and check where the TV lands.
func TestMenuStandbyCycle(t *testing.T) {
	if !*powerTests {
		t.Skip("-power=false")
	}
	pa, err := guevennePA()
	if err != nil {
		t.Fatalf("no physical address: %v", err)
	}
	requireTV(t, "on")
	t.Cleanup(func() {
		if err := requireHomeScreen(); err != nil {
			t.Errorf("teardown: %v", err)
		}
		restoreTVOn(t)
	})

	// Capture the whole test, not just the wake: the TV emits its routing
	// messages across the standby and wake together, and a window opened later
	// misses them entirely.
	const log = "/tmp/tvtest-cycle.log"
	if err := cecMonitorStart(log, 300); err != nil {
		t.Fatalf("could not monitor the CEC bus: %v", err)
	}

	// Start from the Pi's input so the wake at the end has to route back to
	// guevenne -- the regression being guarded here is landing on the Pi. As
	// above, the TV acknowledges this switch silently, so it cannot be asserted.
	if err := setTVInput(piPhysAddr); err != nil {
		t.Fatalf("setup: could not switch the TV to the Pi's input: %v", err)
	}
	time.Sleep(10 * time.Second)

	m, err := openPowerMenu()
	if err != nil {
		t.Skipf("could not open the power menu: %v", err)
	}
	// Navigate by label and activate only once the DOM confirms the right row
	// holds focus. Its neighbours suspend and restart the machine.
	if err := stepToLabel("Turn Off TV", keyDown, len(m.Rows)+2); err != nil {
		t.Fatalf("could not focus the row: %v", err)
	}
	if err := activateRow("Turn Off TV"); err != nil {
		t.Fatalf("%v", err)
	}
	if !waitTV("standby", 90*time.Second) {
		t.Fatalf("menu selection did not turn the TV off (state %q)", tvStatus())
	}

	// The menu should have closed itself once standby succeeded.
	if after, err := readMenu(); err == nil && after.Open {
		t.Errorf("power menu stayed open after standby: %s", after)
	}

	// Let the TV finish powering down before waking it, and start the capture
	// after that wait so the window still covers the wake itself.
	time.Sleep(tvSettleBeforeWake)
	for attempt := 1; ; attempt++ {
		if _, err := run(guevenne, "tv wake"); err != nil {
			t.Fatalf("tv wake failed: %v", err)
		}
		if waitTV("on", 60*time.Second) {
			break
		}
		if attempt == 2 {
			t.Fatalf("TV did not come back on (state %q)", tvStatus())
		}
	}
	got := waitLastRouting(log, 25*time.Second)
	if got == "" {
		t.Fatalf("TV announced no routing change; cannot confirm it returned to guevenne")
	}
	if !strings.HasPrefix(got, strings.Split(pa, ".")[0]) {
		t.Errorf("after a menu standby cycle the TV routed to %s, want guevenne's %s", got, pa)
	}
}

// The `tv` script runs both from an interactive shell and from the
// steam-tv-menu user service, whose PATH is minimal. A bare `awk` worked over
// ssh and failed from the menu, so `tv standby` sent standby without claiming
// Active Source and the TV fell back to the Pi's input. Every external command
// it calls must therefore be an absolute store path.
func TestTVScriptHasNoAmbientPathDeps(t *testing.T) {
	script, err := run(guevenne, "cat $(readlink -f $(command -v tv))")
	if err != nil {
		t.Fatalf("could not read the tv script: %v", err)
	}
	risky := []string{"awk", "sed", "grep", "cut", "tr", "edid-decode"}
	for _, line := range strings.Split(script, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		for _, cmd := range risky {
			if strings.Contains(line, "/bin/"+cmd) {
				continue
			}
			for _, sep := range []string{" " + cmd + " ", "|" + cmd + " ", "| " + cmd + " ", "$(" + cmd + " "} {
				if strings.Contains(line, sep) {
					t.Errorf("bare %q depends on ambient PATH: %s", cmd, trimmed)
					break
				}
			}
		}
	}
}

// restoreTVOn returns the TV to on after a power test and verifies it, so a
// test that leaves the TV off reports that instead of handing the next test a
// silently wrong starting state.
func restoreTVOn(t *testing.T) {
	t.Helper()
	if tvStatus() == "on" {
		return
	}
	if err := wakeTV(); err != nil {
		t.Errorf("teardown: %v", err)
	}
}

// tvSettleBeforeWake is how long the TV needs after entering standby before it
// will honour a wake.
//
// Waking sooner is accepted on the wire -- the service returns OK -- and then
// silently ignored, leaving the TV off. Measured reproducibly: a wake ~2s
// after standby leaves it off (it even reports a transient "unknown" before
// settling back to standby), while the same wake ~17s later works every time.
const tvSettleBeforeWake = 25 * time.Second

// wakeTV brings the TV back on, allowing for the settle above and retrying,
// because a single ignored wake is indistinguishable from a broken one.
func wakeTV() error {
	time.Sleep(tvSettleBeforeWake)
	for attempt := 1; attempt <= 3; attempt++ {
		if _, err := run(guevenne, "tv wake"); err != nil {
			return err
		}
		if waitTV("on", 60*time.Second) {
			return nil
		}
	}
	return fmt.Errorf("TV stayed %q after 3 wake attempts", tvStatus())
}
