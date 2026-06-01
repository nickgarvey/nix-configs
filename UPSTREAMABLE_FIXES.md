# Upstreamable Fixes

Local nixpkgs workarounds in this repo that should eventually be PR'd upstream.
Each entry should describe the bug, where it's worked around locally, and what
the upstream fix should look like.

---

## orca-slicer: wrapper missing `GST_PLUGIN_SCANNER`, causing SIGSEGV in Monitor tab

**Affected:** `pkgs/by-name/or/orca-slicer/package.nix` (nixpkgs)
**Local workaround:** `hosts/dovahkiin/configuration.nix` — `orca-slicer.overrideAttrs` adds `--set GST_PLUGIN_SCANNER` to `gappsWrapperArgs`.

### Symptom

OrcaSlicer segfaults when the Monitor (printer camera) tab is constructed. On
some launches the crash happens at startup because MainFrame builds the Monitor
panel eagerly; on others it triggers when switching to the tab.

Crash stack (from `coredumpctl` / `gdb`):

```
SIGSEGV in wxMediaCtrl2::wxMediaCtrl2(wxWindow*)
  Slic3r::GUI::StatusBasePanel::create_monitoring_page()
  Slic3r::GUI::StatusBasePanel::StatusBasePanel(...)
  Slic3r::GUI::StatusPanel::StatusPanel(...)
  Slic3r::GUI::MonitorPanel::init_tabpanel()
  Slic3r::GUI::MainFrame::init_tabpanel()
  ...
```

### Root cause

With `GST_DEBUG=2` the preceding GStreamer log line is:

```
WARN GST_ELEMENT_FACTORY no such element factory "playbin"!
```

Disassembly around the faulting instruction shows the constructor calls
`gst_element_factory_make("playbin", ...)`, does not null-check the result, and
then dereferences it via `g_object_set` — `%rax = 0x2c8(%rbx)` is `NULL`.

`playbin` is missing from the GStreamer registry because GStreamer can't find
its plugin-scanner helper at runtime. The current nixpkgs wrapper sets:

- `GST_PLUGIN_SYSTEM_PATH_1_0` — where the plugin `.so`s live ✅
- `GST_PLUGIN_SCANNER` — the path to `gst-plugin-scanner` ❌ (missing)

`gst-plugin-scanner` is the out-of-process helper that introspects each plugin
to populate the registry. Without it, registry generation silently produces a
near-empty cache (observed at ~7 KB vs. ~1 MB after the fix) and most plugins —
including `playbin` from `gst-plugins-base`'s `libgstplayback.so` — are absent.

### Reproduction (clean shell)

```sh
rm -f ~/.cache/gstreamer-1.0/registry.x86_64.bin
orca-slicer    # crashes (Monitor tab or startup)
```

### Verification of fix

```sh
rm -f ~/.cache/gstreamer-1.0/registry.x86_64.bin
GST_PLUGIN_SCANNER=/nix/store/.../gstreamer-1.26.11/libexec/gstreamer-1.0/gst-plugin-scanner \
  orca-slicer
# Registry rebuilds to ~1 MB; Monitor tab opens without crashing.
```

### Suggested upstream patch

In `pkgs/by-name/or/orca-slicer/package.nix`, extend the existing `preFixup`:

```nix
preFixup = ''
  gappsWrapperArgs+=(
    --prefix LD_LIBRARY_PATH : "$out/lib:${lib.makeLibraryPath [ glew ]}"
    --set WEBKIT_DISABLE_COMPOSITING_MODE 1
    --set FONTCONFIG_FILE "${fontsConf}"
    --set GST_PLUGIN_SCANNER "${gst_all_1.gstreamer}/libexec/gstreamer-1.0/gst-plugin-scanner"
    ...
  )
'';
```

Note: `wrapGAppsHook3` does not automatically propagate `GST_PLUGIN_SCANNER`
even when `gst_all_1.gstreamer` is in `buildInputs`. Other GStreamer-using
packages in nixpkgs may have the same latent bug and could be audited.

---

## mainsail: nginx `upstreams` server key not IPv6-safe

**Affected:** `nixos/modules/services/web-apps/mainsail.nix` (nixpkgs)
**Local workaround:** branch `mainsail-ipv6-upstream` in `~/projects/nixpkgs` (one-line patch, not yet committed/PR'd).

### Symptom

When `services.moonraker.address` is an IPv6 literal (e.g. `::1`), the mainsail
module generates an nginx `upstream` server entry like:

```
server ::1:7125;
```

which nginx rejects — IPv6 literals in `server` directives must be bracketed
(`[::1]:7125`). The mainsail vhost then fails to start.

### Root cause

`mainsail.nix` interpolates `moonraker.address` directly into the upstream
server key:

```nix
upstreams.mainsail-apiserver.servers."${moonraker.address}:${toString moonraker.port}" = { };
```

There's no bracketing for IPv6 hosts.

### Patch

Adds a small helper and uses it for the server key:

```diff
 let
   cfg = config.services.mainsail;
   moonraker = config.services.moonraker;
+  escapedHost = host: if lib.hasInfix ":" host then "[${host}]" else host;
 in
 ...
-      upstreams.mainsail-apiserver.servers."${moonraker.address}:${toString moonraker.port}" = { };
+      upstreams.mainsail-apiserver.servers."${escapedHost moonraker.address}:${toString moonraker.port}" = { };
```

### Notes for upstreaming

- The sibling `fluidd.nix` module almost certainly has the same bug — check and
  fix in the same PR.
- `lib.hasInfix ":"` is a reasonable proxy for "is this an IPv6 literal" since
  hostnames and IPv4 addresses can't contain `:`. Alternatively, the helper
  could live in `lib` since this pattern recurs across nginx-using modules.

---

## OrcaSlicer: two NULL-deref crashes (upstream to OrcaSlicer, not nixpkgs)

**Affected:** `SoftFever/OrcaSlicer` — verified against tag `v2.3.2`, partially still in `master`.
**Local workaround:** `patches/orca-slicer-null-checks.patch`, applied via `overrideAttrs` in `hosts/dovahkiin/configuration.nix`.

### Bug 1: `Plater.cpp:6042` — unchecked `option<ConfigOptionStrings>("filament_colour")`

```cpp
project_filament_count = config_loaded.option<ConfigOptionStrings>("filament_colour")->size();
```

If a loaded 3mf project's parsed config doesn't expose `filament_colour` as a
`ConfigOptionStrings` (e.g. a 3mf produced by Creality Print for a printer
profile the user doesn't have installed locally), `option<...>(name, false)`
returns `nullptr`, and the immediate `->size()` virtual call segfaults on the
vtable load. Reproduced opening a Creality-Print-generated 3mf for an Ender-3
V3 SE without that printer profile installed.

**Status in master:** unchanged as of cloning (commit `c383587a`).

### Bug 2: `wxMediaCtrl2.cpp:45` — unchecked `m_imp` and inner playbin

```cpp
auto playbin = reinterpret_cast<wxGStreamerMediaBackend *>(m_imp)->m_playbin;
g_object_set (G_OBJECT (playbin), "audio-sink", NULL, NULL);
```

If `wxMediaCtrl::Create` can't construct a working GStreamer backend (e.g.
`playbin` element missing from the registry, which happens on NixOS when the
`GST_PLUGIN_SCANNER` env var isn't set — see the orca-slicer nixpkgs entry
above), `m_imp` is `nullptr` and dereferencing it segfaults.

**Status in master:** partially fixed (`m_imp` is now null-checked), but the
inner `playbin` pointer is still dereferenced unconditionally. Our patch
guards both.

### Patch

See `patches/orca-slicer-null-checks.patch`. Both hunks are minimal defensive
null-checks; they don't try to recover or signal the user, just avoid the
crash. A proper upstream fix would probably also surface a UI notification
explaining the missing profile / missing GStreamer plugin.
