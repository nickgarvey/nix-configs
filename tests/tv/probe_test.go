// Diagnostic, not a regression test. Dumps what Steam's UI actually looks like,
// across every CEF target, so navigation code is written against observed
// structure rather than guessed selectors.
//
//	go test -dump -run TestDumpUI -v ./...             # current state
//	go test -dump -dump-open -run TestDumpUI -v ./...  # after pressing KEY_MENU
package tvtest

import (
	"flag"
	"testing"
	"time"
)

var (
	dump     = flag.Bool("dump", false, "run the UI dump diagnostic")
	dumpOpen = flag.Bool("dump-open", false, "press KEY_MENU before dumping")
	dumpKeys = flag.String("dump-keys", "", "ydotool script to run before dumping")
)

// snapshotJS reports where focus is, its ancestor chain, and every plausible
// menu row, along with the classes that identify each.
const snapshotJS = `(function(){
  function d(e){ return {tag:e.tagName, cls:String(e.className).slice(0,80), txt:(e.textContent||"").trim().slice(0,40)}; }
  var f = document.querySelector(".gpfocus");
  var chain = [];
  for (var p = f; p && chain.length < 6; p = p.parentElement) chain.push(d(p));
  var rows = [], all = document.querySelectorAll("div,button");
  for (var i = 0; i < all.length && rows.length < 40; i++) {
    var c = String(all[i].className);
    if (/menuitem|contextmenu|quickaccess|drawer/i.test(c)) rows.push(d(all[i]));
  }
  return JSON.stringify({url:location.href.slice(0,60), bodyKids:document.body?document.body.children.length:-1,
    focusCount:document.querySelectorAll(".gpfocus").length, focused:f?d(f):null, chain:chain, rows:rows}, null, 1);
})()`

func TestDumpUI(t *testing.T) {
	if !*dump {
		t.Skip("-dump not set")
	}
	if *dumpKeys != "" {
		if err := ensureYdotoold(); err != nil {
			t.Fatalf("ydotoold: %v", err)
		}
		if err := ydo(*dumpKeys); err != nil {
			t.Fatalf("key send: %v", err)
		}
		time.Sleep(4 * time.Second)
	}
	if *dumpOpen {
		if err := ensureYdotoold(); err != nil {
			t.Fatalf("ydotoold: %v", err)
		}
		if err := ydo(`ydotool key 1:1 1:0; sleep 1.5; ydotool key 139:1 139:0`); err != nil {
			t.Fatalf("key send: %v", err)
		}
		time.Sleep(4 * time.Second)
	}
	ts, err := cdpTargets()
	if err != nil {
		t.Fatalf("target list: %v", err)
	}
	for _, tg := range ts {
		if tg.WS == "" {
			continue
		}
		out, err := cdpEval(tg.Title, snapshotJS)
		if err != nil {
			t.Logf("=== %s === unreadable: %v", tg.Title, err)
			continue
		}
		t.Logf("=== %s ===\n%s", tg.Title, out)
	}
}

var dumpWatch = flag.Int("dump-watch", 0, "after -dump-keys, poll menu state for N seconds")

// TestWatchMenu shows how the menu state evolves after a key sequence, which
// is how the open sequence was diagnosed rather than guessed at.
func TestWatchMenu(t *testing.T) {
	if *dumpWatch == 0 {
		t.Skip("-dump-watch not set")
	}
	if err := ensureYdotoold(); err != nil {
		t.Fatalf("ydotoold: %v", err)
	}
	before, err := readMenu()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	t.Logf("t=0 (before keys): %s", before)
	if *dumpKeys != "" {
		if err := ydo(*dumpKeys); err != nil {
			t.Fatalf("key send: %v", err)
		}
	}
	start := time.Now()
	prev := ""
	for i := 0; i < *dumpWatch; i++ {
		m, err := readMenu()
		s := m.String()
		if err != nil {
			s = "read error: " + err.Error()
		}
		if s != prev {
			t.Logf("t=%.1fs %s", time.Since(start).Seconds(), s)
			prev = s
		}
		time.Sleep(time.Second)
	}
}

// TestWatchFocus polls the UI while the key sequence is still being typed, so
// intermediate states are visible instead of only the end state.
func TestWatchFocus(t *testing.T) {
	if *dumpWatch == 0 {
		t.Skip("-dump-watch not set")
	}
	if err := ensureYdotoold(); err != nil {
		t.Fatalf("ydotoold: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- ydo(*dumpKeys) }()

	start := time.Now()
	prev := ""
	for i := 0; i < *dumpWatch; i++ {
		s, err := readFocus()
		if err != nil {
			s = "err: " + err.Error()
		}
		if s != prev {
			t.Logf("t=%5.1fs %s", time.Since(start).Seconds(), s)
			prev = s
		}
	}
	if err := <-done; err != nil {
		t.Logf("key send returned: %v", err)
	}
	t.Logf("final: %s", prev)
}

// TestMenuKeyReliability presses KEY_MENU repeatedly and reports how often it
// actually opens the menu, and what focus looks like when it does.
func TestMenuKeyReliability(t *testing.T) {
	if *dumpWatch == 0 {
		t.Skip("-dump-watch not set")
	}
	if err := ensureYdotoold(); err != nil {
		t.Fatalf("ydotoold: %v", err)
	}
	opened := 0
	for i := 0; i < *dumpWatch; i++ {
		_ = press(keyEsc)
		time.Sleep(time.Second)
		before, _ := readFocus()
		_ = ydo("ydotool key 139:1 139:0")
		time.Sleep(2 * time.Second)
		after, _ := readFocus()
		changed := before != after
		if changed {
			opened++
		}
		t.Logf("attempt %d changed=%v\n  before %s\n  after  %s", i+1, changed, before, after)
	}
	t.Logf("focus changed on %d/%d KEY_MENU presses", opened, *dumpWatch)
}

// TestWhereAmI reports the current screen without touching anything.
func TestWhereAmI(t *testing.T) {
	if !*dump {
		t.Skip("-dump not set")
	}
	for i := 0; i < 5; i++ {
		f, err := readFocus()
		if err != nil {
			t.Logf("%d: err %v", i, err)
		} else {
			t.Logf("%d: %s", i, f)
		}
		time.Sleep(time.Second)
	}
	route, err := cdpEval("Big Picture", `(function(){
	  var f=document.querySelector(".gpfocus");
	  return JSON.stringify({hash:location.hash.slice(0,60),
	    modal: !!document.querySelector(".ModalPosition, [class*='modal']"),
	    focusTag: f?f.tagName+"."+String(f.className).slice(0,60):"none"});
	})()`)
	t.Logf("route: %s (err %v)", route, err)
}

// TestFocusAnywhere reports focus across all targets, which is the read the
// navigation helpers depend on.
func TestFocusAnywhere(t *testing.T) {
	if !*dump {
		t.Skip("-dump not set")
	}
	for i := 0; i < 3; i++ {
		l, tgt, err := focusAnywhere()
		t.Logf("%d: focus=%q in %s (err %v)", i, l, tgt, err)
		time.Sleep(time.Second)
	}
}

// TestFindMenuKey sweeps candidate keycodes and reports which ones open
// Steam's main menu, judged by focus landing in MainMenu_uid2.
func TestFindMenuKey(t *testing.T) {
	if !*dump {
		t.Skip("-dump not set")
	}
	if err := ensureYdotoold(); err != nil {
		t.Fatalf("ydotoold: %v", err)
	}
	candidates := []struct{ name, keys string }{
		{"KEY_MENU(139)", "ydotool key 139:1 139:0"}, //nolint
		{"KEY_COMPOSE(127)", "ydotool key 127:1 127:0"},
		{"KEY_LEFTMETA(125)", "ydotool key 125:1 125:0"},
		{"KEY_F1(59)", "ydotool key 59:1 59:0"},
		{"KEY_HOMEPAGE(172)", "ydotool key 172:1 172:0"},
		{"KEY_BACK(158)", "ydotool key 158:1 158:0"},
		{"Ctrl+Shift+Tab", "ydotool key 29:1 42:1 15:1 15:0 42:0 29:0"},
		{"KEY_F12(88)", "ydotool key 88:1 88:0"},
		{"Shift+Tab", "ydotool key 42:1 15:1 15:0 42:0"},
		{"KEY_ESC(1)", "ydotool key 1:1 1:0"},
	}
	for _, c := range candidates {
		if err := closeMenus(); err != nil {
			t.Logf("%-18s could not reach baseline: %v", c.name, err)
			continue
		}
		if err := ydo(c.keys); err != nil {
			t.Logf("%-18s send failed: %v", c.name, err)
			continue
		}
		focus, ok := waitMainMenu(true, 4*time.Second)
		if ok {
			t.Logf("%-18s OPENS THE MAIN MENU (focus %q)", c.name, focus)
			continue
		}
		label, target, _ := focusAnywhere()
		t.Logf("%-18s no menu (focus %q in %q)", c.name, label, target)
	}
}

func TestRoute(t *testing.T) {
	if !*dump {
		t.Skip("-dump not set")
	}
	r, err := readRoute()
	t.Logf("route=%q err=%v", r, err)
}
