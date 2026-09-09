# TV regression tests

A Go suite covering the `guevenne` TV session and its CEC power control.
Everything in it exists because the corresponding behaviour broke at least once.

```
cd tests/tv
go test ./...                  # full suite; cycles TV power, ~4 min
go test -power=false ./...     # skip the power tests (fast, invisible)
go test -count=3 ./...         # reliability check
go test -dump -run TestDumpUI -v ./...   # diagnostics, see below
```

It drives real hardware over ssh: `guevenne` (the TV box) and `nelkir` (the Pi
on the TV's CEC bus). There is no fake mode — the bugs it catches live in the
interaction between Steam, gamescope, CEC and the TV firmware, and no stub
reproduces those.

## Start and end state

`TestMain` runs a preflight and refuses to test against an unknown baseline:
both hosts answer, `ydotoold` is available, Steam's UI answers over CDP, the
**screen** is driven to `/routes/library/home` and asserted, all menus are
closed, and the TV's power state is recorded (and driven to on).

Afterwards `restore` puts the screen and the TV back, and **fails loudly** if it
cannot — being left with a TV in the wrong state and no warning is worse than a
noisy failure.

Per test: `requireTV` drives power and asserts it took; `menuTest` asserts the
home screen before *and* after; `openPowerMenu` re-establishes a closed-menu
baseline before sending a key; `restoreTVOn` verifies the TV came back.

## Things that are true about this hardware

These were each learned the hard way; changing the code without them will
reintroduce a bug that already shipped once.

**The TV needs ~25s after standby before it will honour a wake.** Waking sooner
is accepted on the wire (the service returns `OK`) and silently ignored, leaving
the TV off. See `tvSettleBeforeWake`.

**Never assert on a message we transmitted.** `tv wake` makes nelkir transmit
`SET_STREAM_PATH`, so a naive capture check passes on the echo of its own
command with the TV doing nothing. `routingAwk` matches only `Received from TV`.

**The TV announces only changes it initiates.** Ask it to switch inputs and it
complies silently. So the routing tests drive the starting input to the Pi
(`3.0.0.0`) — best-effort and deliberately unasserted, because it is
unobservable — which makes the wake back to guevenne a change the TV *does*
announce.

**`ACTIVE_SOURCE 0.0.0.0` is the TV claiming itself** during a wake and says
nothing about which HDMI input is on screen. Only `SET_STREAM_PATH` and
`ROUTING_CHANGE` select an input.

**Steam's UI spans several CEF targets.** The main menu lives in
`MainMenu_uid2`; context menus render in the Big Picture target. Reading one
target makes an open menu look like no menu, so state reads sweep them all.

**Escape opens the main menu as well as closing menus.** Shift+Tab is used to
open and Escape only to close, because a key that does both turns the outcome
into a parity puzzle — which is exactly what made the original harness flaky.

**`KEY_MENU` (139) does nothing.** It was never the key that opened anything.

**Input must go through uinput.** `xdotool` does not work; Steam ignores
synthetic X events. `ydotoold` is started ad hoc by preflight — not declarative.

**Never reload the Big Picture CEF target.** `Page.reload` knocks Steam into
desktop mode and blanks the TV; recovery is a reboot.

**Scope journal assertions to the unit's current invocation.** A fixed line
count scrolls the interesting line away exactly when the suite is exercising
the feature hardest.

## What each test covers

| Test | Bug it would have caught |
| --- | --- |
| `GamescopeSessionRunning` | session dying in a loop at boot |
| `TwoXwaylandServers` | one Xwayland — QtWebEngine children die |
| `OnlyHDMIOutputEnabled` | the broken internal panel getting the session |
| `AudioRoutesToTV` | wireplumber rule silently rejected, sound lost |
| `CECSocketListening`, `CECAudioGuardActive` | services not started after a rebuild |
| `SteamRunning` | Big Picture gone while gamescope survives |
| `CECRejectsUnknownSource` | the allowlist regressing — the socket is unauthenticated on the LAN |
| `CECStatusVerb`, `CECRejectsBadVerb` | the socket protocol answering nonsense, or accepting verbs it should refuse |
| `PhysicalAddressFromEDID` | a hardcoded HDMI port; re-cabling must not break input switching |
| `MenuInjectorRunning`/`Connected` | injector up but never attached to Steam's UI |
| `PowerMenu/has Turn Off TV` | injection stopped applying |
| `PowerMenu/Switch to Desktop replaced` | the original row returning — a controller press would then black-screen the TV |
| `PowerMenu/row is focusable` | an entry the controller cannot reach; the reason the row is hijacked rather than appended |
| `TVScriptHasNoAmbientPathDeps` | `tv` calling a bare `awk`, absent from the service PATH — standby and wake then went out with no Active Source claim and the TV fell back to the Pi |
| `StandbyStaysOff` | `cec-audio-guard` reasserting routing and waking the TV back up |
| `MenuStandbyCycle` | both halves of the reported regression: standby is ignored unless sent from the active source, and the wake lands on the Pi's input because the Pi answers `REQUEST_ACTIVE_SOURCE` |

## Diagnostics

`probe_test.go` holds flag-gated tools, skipped in normal runs. They are how the
DOM selectors and the menu key were determined, rather than guessed:

```
go test -dump -run TestDumpUI -v ./...        # DOM across every CEF target
go test -dump -run TestWhereAmI -v ./...      # what screen is up
go test -dump -run TestFindMenuKey -v ./...   # which keycodes open the menu
go test -dump-watch 40 -dump-keys '<ydotool script>' -run TestWatchFocus -v ./...
```

## Not covered

These need a person at the TV. All four were checked by hand on 2026-09-08 and
worked; re-check them after any change to the session, the `tv` script or the
CEC service.

- Physical Steam Controller presses. All input here is synthetic through uinput,
  and Steam treats real controller input differently, so selecting "Turn Off TV"
  with the pad in hand is the only proof that path works.
- The controller-connect wake (`tv-wake.service`, fired by a udev rule). The
  tests call `tv wake` directly; nothing exercises the udev trigger. This is
  where the bare-`awk` bug lived: the service PATH lacks gawk, so `mypa()`
  returned empty, `source <pa>` was never sent, and the TV woke onto whichever
  input it last showed. A healthy run logs *two* `OK`s -- one for `on`, one for
  `source`. One `OK` and an `ERR no phys-addr in EDID` is the bug returning.
- Jellyfin video playback. The client launches and logs in under test; no test
  plays a file, so decode, HDMI audio during playback, and controller input
  inside the player are all unverified by machine.
- The YouTube app rendering its TV interface rather than the desktop site. It
  is a Chromium `--app` window with a TV user-agent; a regression here shows up
  as the desktop site, which the D-pad cannot drive.
- Whether the TV is *actually* displaying guevenne. The current input cannot be
  polled: nelkir answers `REQUEST_ACTIVE_SOURCE` itself and guevenne has no CEC
  adapter. It is only observable at a transition the TV announces.
- Whether the panel is physically lit. `REPORT_POWER_STATUS` has been seen stuck
  at `standby` while the TV was on; ELD, DRM `status`, `dpms` and the audio sink
  are all identical whether the TV is on or off.

For these, `docs/guevenne-recovery.md` has the manual checklist.

## Why the suite is shaped this way

TV power transitions dominate the runtime — a standby/wake cycle cannot go
faster than the hardware, which needs ~25s of settle before it will wake. So
the suite is deliberately small where it is slow.

`MenuStandbyCycle` drives the real user path (the Power menu row) and asserts
both halves: the TV reaches standby, and the wake routes back to guevenne.
Separate `StandbyTurnsTVOff` and `WakeRoutesToGuevenne` tests existed and were
removed as redundant — they asserted the same two things through the CLI
instead of the menu, for another 140s per run.

The trade to know about: when `MenuStandbyCycle` fails, it does not say which
half broke. If you are debugging one, `tv standby` and `tv wake` over ssh
isolate it in a few seconds, and `-dump` diagnostics in `probe_test.go` cover
the menu side.

Similarly the three Power-menu assertions are subtests of a single menu open,
because opening the menu costs ~20s and they all judge the same `menuState`.
