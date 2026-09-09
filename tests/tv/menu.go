package tvtest

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// menuStateJS reads Steam's context menu structurally. The selectors come from
// the live DOM (see probe_test.go): div.BasicUIContextMenu is the container,
// each row is div.contextMenuItem, and the row the controller would activate
// carries .gpfocus.
const menuStateJS = `(function(){
  var m = document.querySelector("div.BasicUIContextMenu");
  var f = document.querySelector("div.contextMenuItem.gpfocus");
  var rows = [];
  if (m) {
    var n = m.querySelectorAll("div.contextMenuItem");
    for (var i = 0; i < n.length; i++) rows.push((n[i].textContent||"").trim());
  }
  var title = "";
  if (m && rows.length) {
    var whole = (m.textContent||"").trim();
    var first = whole.indexOf(rows[0]);
    if (first > 0) title = whole.slice(0, first).trim();
  }
  return JSON.stringify({open: !!m, title: title, rows: rows,
    focused: f ? (f.textContent||"").trim() : ""});
})()`

// menuState is what the UI actually shows right now.
type menuState struct {
	Open    bool     `json:"open"`
	Title   string   `json:"title"`
	Rows    []string `json:"rows"`
	Focused string   `json:"focused"`
}

func (m menuState) String() string {
	if !m.Open {
		return "menu closed"
	}
	return fmt.Sprintf("menu %q rows=%v focused=%q", m.Title, m.Rows, m.Focused)
}

func (m menuState) has(label string) bool {
	for _, r := range m.Rows {
		if r == label {
			return true
		}
	}
	return false
}

// readMenu finds the open context menu in whichever target holds it.
func readMenu() (menuState, error) {
	var m menuState
	res, err := cdpEvalAll(menuStateJS)
	if err != nil {
		return m, err
	}
	if len(res) == 0 {
		return m, fmt.Errorf("no CEF target answered; is Steam still in Big Picture?")
	}
	for _, v := range res {
		var cur menuState
		if err := json.Unmarshal([]byte(v), &cur); err != nil {
			continue
		}
		if cur.Open {
			return cur, nil
		}
	}
	return m, nil
}

// waitMenu polls until the menu satisfies cond, returning the last state seen
// either way so failures can report what was actually on screen.
func waitMenu(cond func(menuState) bool, timeout time.Duration) (menuState, bool) {
	deadline := time.Now().Add(timeout)
	var last menuState
	for {
		m, err := readMenu()
		if err == nil {
			last = m
			if cond(m) {
				return m, true
			}
		}
		if time.Now().After(deadline) {
			return last, false
		}
		time.Sleep(time.Second)
	}
}

const (
	keyEsc   = "1"
	keyEnter = "28"
	keyUp    = "103"
	keyDown  = "108"
	// Shift+Tab opens Steam's main menu. Escape also opens it, but Escape is
	// how menus are closed, and a key that both opens and closes invites
	// toggling races -- the original harness pressed Escape three times and
	// depended on parity for whether the menu ended up open.
	keyShift = "42"
	keyTab   = "15"
)

func press(keys ...string) error {
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "ydotool key %s:1 %s:0; sleep 0.4; ", k, k)
	}
	return ydo(b.String())
}

// uiFocusJS reports focus anywhere in the UI, not just inside a context menu,
// so intermediate states (the main menu drawer, the home screen) are visible.
const uiFocusJS = `(function(){
  var f = document.querySelector(".gpfocus");
  var m = document.querySelector("div.BasicUIContextMenu");
  return JSON.stringify({focus: f ? (f.textContent||"").trim().slice(0,30) : "",
    ctx: !!m, ctxTitle: m ? (m.textContent||"").trim().slice(0,18) : ""});
})()`

func readFocus() (string, error) {
	return cdpEval("Big Picture", uiFocusJS)
}

// focusLabel is the text of whatever the controller would act on right now,
// anywhere in the UI -- main menu, context menu or a home-screen tile.
func focusLabel() (string, error) {
	label, _, err := focusAnywhere()
	return label, err
}

// stepToLabel walks focus with the given key until the focused element is
// want. It stops early when focus stops moving, which is what hitting the end
// of a list looks like, and reports the labels it saw so a failure says where
// navigation actually went.
func stepToLabel(want, key string, maxSteps int) error {
	seen := []string{}
	cur, err := focusLabel()
	if err != nil {
		return err
	}
	for i := 0; i < maxSteps; i++ {
		if cur == want {
			return nil
		}
		seen = append(seen, cur)
		if err := press(key); err != nil {
			return err
		}
		time.Sleep(700 * time.Millisecond)
		next, err := focusLabel()
		if err != nil {
			return err
		}
		if next == cur {
			return fmt.Errorf("focus stuck at %q looking for %q (saw %v)", cur, want, seen)
		}
		cur = next
	}
	return fmt.Errorf("did not reach %q in %d steps (saw %v)", want, maxSteps, seen)
}

// activateRow presses Enter only once the DOM confirms the intended row holds
// focus. Never press Enter blind in the Power menu -- the neighbouring rows
// suspend and restart the machine.
func activateRow(want string) error {
	got, err := focusLabel()
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("refusing to activate: focus is %q, wanted %q", got, want)
	}
	return press(keyEnter)
}

// openPowerMenu opens Steam's Power context menu and returns its state.
//
// Every step is confirmed against the DOM before the next key is sent. In
// particular, if Shift+Tab does not open anything, this reports that and sends
// nothing further -- a blind Down/Enter sequence at that point types into
// whatever screen Steam is showing.
func openPowerMenu() (menuState, error) {
	var zero menuState
	if err := closeMenus(); err != nil {
		return zero, fmt.Errorf("could not reach a closed-menu baseline: %w", err)
	}
	var errs []string
	for attempt := 1; attempt <= 3; attempt++ {
		if err := ydo("ydotool key " + keyShift + ":1 " + keyTab + ":1 " + keyTab + ":0 " + keyShift + ":0"); err != nil {
			return zero, err
		}
		// The menu is open when focus moves into Steam's main-menu target.
		if _, ok := waitMainMenu(true, 6*time.Second); !ok {
			label, target, _ := focusAnywhere()
			errs = append(errs, fmt.Sprintf(
				"attempt %d: Shift+Tab did not open the main menu (focus %q in %q)", attempt, label, target))
			continue
		}
		if err := stepToLabel("Power", keyDown, 12); err != nil {
			errs = append(errs, fmt.Sprintf("attempt %d: %v", attempt, err))
			_ = closeMenus()
			continue
		}
		if err := activateRow("Power"); err != nil {
			errs = append(errs, fmt.Sprintf("attempt %d: %v", attempt, err))
			_ = closeMenus()
			continue
		}
		m, ok := waitMenu(func(m menuState) bool { return m.Open && m.has("Suspend System") }, 8*time.Second)
		if ok {
			return m, nil
		}
		errs = append(errs, fmt.Sprintf("attempt %d: power submenu never appeared (%s)", attempt, m))
		_ = closeMenus()
	}
	return zero, fmt.Errorf("%s", strings.Join(errs, "; "))
}

// closeMenus returns the UI to a closed-menu baseline and verifies it, so a
// test never inherits a menu left open by the previous one.
// The baseline is both no context menu and no main menu: Steam's main menu
// lives in its own target, so checking only for a context menu would call an
// open main menu "closed" and leave the next test typing into it.
func closeMenus() error {
	for attempt := 0; attempt < 5; attempt++ {
		ctx, ctxErr := readMenu()
		main, _, mainErr := mainMenuOpen()
		if ctxErr == nil && mainErr == nil && !ctx.Open && !main {
			return nil
		}
		if err := press(keyEsc); err != nil {
			return err
		}
		time.Sleep(1500 * time.Millisecond)
	}
	ctx, _ := readMenu()
	_, focus, _ := mainMenuOpen()
	return fmt.Errorf("menus still open after 5 escapes: context %s, main-menu focus %q", ctx, focus)
}

// focusAnywhere returns the label of the focused element and the target it was
// found in, searching every CEF target. When the main menu is open, focus is
// in MainMenu_uid2 rather than the Big Picture target.
func focusAnywhere() (label, target string, err error) {
	res, err := cdpEvalAll(`(function(){
	  var f = document.querySelector(".gpfocus");
	  return f ? (f.textContent||"").trim() : "";
	})()`)
	if err != nil {
		return "", "", err
	}
	for tgt, v := range res {
		if v != "" {
			return v, tgt, nil
		}
	}
	return "", "", nil
}

// mainMenuTarget is the CEF target Steam renders its main menu into. Focus
// living there is the signal that the menu is open -- the Big Picture target
// reports no focus at all while it is up.
const mainMenuTarget = "MainMenu_uid2"

// mainMenuOpen reports whether Steam's main menu is up, and what it has focused.
func mainMenuOpen() (open bool, focus string, err error) {
	label, target, err := focusAnywhere()
	if err != nil {
		return false, "", err
	}
	return target == mainMenuTarget && label != "", label, nil
}

// waitMainMenu polls for the main menu to reach the wanted open state.
func waitMainMenu(want bool, timeout time.Duration) (string, bool) {
	deadline := time.Now().Add(timeout)
	for {
		open, focus, err := mainMenuOpen()
		if err == nil && open == want {
			return focus, true
		}
		if time.Now().After(deadline) {
			return focus, false
		}
		time.Sleep(time.Second)
	}
}

// sharedJSTarget renders Steam's routed UI; its location names the screen the
// user is looking at, which is how "what screen are we on" is asserted.
const sharedJSTarget = "SharedJSContext"

const homeRoute = "/routes/library/home"

// readRoute returns Steam's current route, e.g. /routes/library/home.
func readRoute() (string, error) {
	res, err := cdpEvalAll(`location.pathname`)
	if err != nil {
		return "", err
	}
	if v, ok := res[sharedJSTarget]; ok && v != "" {
		return v, nil
	}
	return "", fmt.Errorf("%s did not report a route", sharedJSTarget)
}

// requireHomeScreen drives Steam back to its home screen and asserts it got
// there. Without this a test inherits whatever screen the previous one left --
// a game page, say -- where the menu rows differ and navigation means something
// else entirely.
func requireHomeScreen() error {
	route, err := readRoute()
	if err != nil {
		return err
	}
	if route == homeRoute {
		return closeMenus()
	}
	if err := closeMenus(); err != nil {
		return err
	}
	// Home is reachable from the main menu, which is where Shift+Tab lands.
	if err := ydo("ydotool key " + keyShift + ":1 " + keyTab + ":1 " + keyTab + ":0 " + keyShift + ":0"); err != nil {
		return err
	}
	if _, ok := waitMainMenu(true, 6*time.Second); !ok {
		return fmt.Errorf("cannot reach home: main menu would not open (route %s)", route)
	}
	if err := stepToLabel("Home", keyUp, 12); err != nil {
		return fmt.Errorf("cannot reach home: %w", err)
	}
	if err := activateRow("Home"); err != nil {
		return err
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(time.Second)
		if r, err := readRoute(); err == nil && r == homeRoute {
			return closeMenus()
		}
	}
	r, _ := readRoute()
	return fmt.Errorf("drove to Home but route is %s, want %s", r, homeRoute)
}
