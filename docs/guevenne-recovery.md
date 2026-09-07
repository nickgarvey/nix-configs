# Rebuilding guevenne's home state

`nixos-anywhere --flake .#guevenne` gets you a working TV box: the gamescope Steam
session, greetd autologin, the display pinned to HDMI-A-1, audio forced to the TV, both
app launchers, and the patched jellyfin-desktop build. What it does **not** get you is
anything that lives in `~`, because Steam and Jellyfin Media Player both own their config
and rewrite it at runtime.

This is the list of what to redo, in order, and the two things that will waste your
afternoon if you don't know them going in.

Nothing here is secret — guevenne has no sops secrets — so this file is safe to read
end to end before you start.

---

## 0. Before anything: let Steam finish bootstrapping

**On a fresh install the TV will look catastrophically broken.** greetd autologins, the
screen flashes, and you land back at the greeter. It repeats on every boot. Nothing in
the Nix config is wrong.

The cause is that Steam has never run. On first launch it downloads its client
(~74 MB, ending up around 3 GB) and then **re-execs itself**; gamescope sees its primary child
exit, logs `launch: Primary child shut down!`, and tears the session down after about two
seconds. Every boot restarts the download from where it left off and dies again.

Fix it once, over SSH, before touching the TV:

```sh
ssh guevenne
XDG_RUNTIME_DIR=/run/user/1000 timeout 600 steam -tenfoot </dev/null
du -sh ~/.local/share/Steam        # want multiple GB, not ~74M
```

Reboot and the session stays up. This is first-boot-only.

## 1. Sign in to Steam

At the TV, with the controller. `Remember Me` so it survives reboots. Everything after
this depends on the account existing, because Steam's per-account `userdata/` directory
is where the shortcuts live.

## 2. Re-add the two non-Steam shortcuts

Steam → Add a Non-Steam Game, twice:

| Name | Target |
|---|---|
| Jellyfin | `/run/current-system/sw/bin/jellyfin-tv` |
| YouTube | `/run/current-system/sw/bin/youtube-tv` |

Both are wrapper scripts the Nix config provides, so the paths are stable. Enable
`AllowDesktopConfig` / overlay if you want a per-app controller mapping.

These land in `~/.local/share/Steam/userdata/<account>/config/shortcuts.vdf`, a binary
file Steam rewrites on exit — which is why it isn't managed declaratively. Recreating it
by hand is a minute's work; generating it is not worth the fight.

Steam assigns each shortcut a fresh `appid`, so any `steam://rungameid/...` links you
had written down are invalidated. Nothing in the config depends on them.

## 3. Sign in to Jellyfin and set the TV layout

Launch the Jellyfin tile. Server is `https://jellyfin.garvey.sh` — LAN resolution is
IPv6-only via the split-horizon override in `modules/networking/dns.nix`, so if it can't
reach the server, check the box actually has its static AAAA before blaming Jellyfin.

Then Settings → Display → Layout → **TV**. Without it you get the desktop layout, which
is unreadable at couch distance.

That preference lives in the web client's `localStorage` inside JMP's QtWebEngine
profile, i.e. a LevelDB blob — not a file worth managing. It may also be redundant now:
jellyfin-web asks the host app via `appHost.getDefaultLayout()`, JMP feeds that from its
`webMode` setting, and that hook only started working once the NativeShell injection bug
was fixed (see `UPSTREAMABLE_FIXES.md`). Worth checking before setting it by hand.

## 4. Recreate the controller input map

This is the one piece that is genuinely hard to reconstruct from memory, so it gets the
most detail.

Without a map, JMP receives the controller but maps nothing useful: Steam Input presents
it as `Microsoft X-Box 360 pad 0`, and JMP's bundled Xbox example does not match, so you
get a flood of raw `KEY_AXIS_2_DOWN` / `KEY_AXIS_5_UP` events from trigger drift and no
navigation at all.

Write this to `~/.local/share/jellyfin-desktop/profiles/<profile-id>/inputmaps/steam-controller.json`
(the profile id is a random UUID — take whatever directory already exists):

```json
{
  "name": "Steam Controller (Steam Input xbox360 emulation)",
  "idmatcher": "Steam Controller.*|Microsoft X-Box.*|XInput.*",
  "mapping": {
    "KEY_BUTTON_0": "enter",
    "KEY_BUTTON_1": { "short": "back", "long": "home" },
    "KEY_BUTTON_6": "back",
    "KEY_BUTTON_7": "home",
    "KEY_HAT_UP": "up",
    "KEY_HAT_DOWN": "down",
    "KEY_HAT_LEFT": "left",
    "KEY_HAT_RIGHT": "right",
    "KEY_AXIS_0_UP": "left",
    "KEY_AXIS_0_DOWN": "right",
    "KEY_AXIS_1_UP": "up",
    "KEY_AXIS_1_DOWN": "down",
    "KEY_AXIS_2_UP": "", "KEY_AXIS_2_DOWN": "",
    "KEY_AXIS_5_UP": "", "KEY_AXIS_5_DOWN": ""
  }
}
```

Three things in there are not guessable, and are why this file is worth documenting
rather than re-deriving:

- **`idmatcher` must match "Steam Controller".** JMP reports that as the source name even
  though SDL calls the device an Xbox 360 pad. The bundled `xbox-controller-windows.json`
  example matches `XInput.*|Microsoft.*joystick driver` and therefore never applies.
- **The d-pad is on the hat, not buttons 11–14.** JMP's own example assumes buttons; this
  pad enumerates as *11 buttons and 6 axes* (JMP logs `JoyStick # 0 is Steam Controller
  with 11 buttons and 6 axes` at startup), so buttons 11–14 do not exist. Buttons 8/9 are
  guide and stick-click, not start/back.
- **Axes 2 and 5 must be bound to `""`.** They are the triggers, they idle noisily, and
  unbound they spam JMP's input queue continuously.

Everything beyond A/B, the d-pad and the left stick (subtitle cycling, seek on the
shoulder buttons) is taste — add from JMP's `inputmaps/examples/` if you want it.

---

## Debugging aids

You cannot see the TV over SSH, and process liveness is not the same as a picture on
screen — assuming otherwise wasted a lot of time the first time round. These give you
eyes and hands:

| Need | Command |
|---|---|
| See the screen | `DISPLAY=:0 gamescopectl screenshot /tmp/tv.png` |
| Send input | `ydotoold` + `YDOTOOL_SOCKET=... ydotool key 28:1 28:0` (uinput; `xdotool` does **not** work, Steam ignores synthetic X events) |
| JMP internals | launch with `--remote-debugging-port=9222`, then drive it over CDP |
| JMP log | `~/.local/share/jellyfin-desktop/profiles/*/logs/jellyfin-desktop.log` |

`Web Client has not connected, handling input in host instead.` in that log means the
NativeShell bridge is down and *all* input is dead — see `UPSTREAMABLE_FIXES.md`, and
note the Qt QML disk-cache trap documented there before you conclude a patch didn't work.

## If the hardware changed

`modules/networking/lan-hosts.nix` pins guevenne's identity to the USB ethernet dongle's
MAC (`00:e0:4c:68:19:5d`), not the laptop. A different dongle means editing that entry,
or the box loses its static AAAA and Jellyfin becomes unreachable on the LAN.
