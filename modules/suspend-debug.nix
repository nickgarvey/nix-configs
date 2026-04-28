{ config, lib, pkgs, ... }:

let
  cfg = config.suspendDebug;

  # systemd-sleep invokes hooks with a near-empty PATH
  # (/usr/sbin:/usr/bin:/sbin:/bin). On NixOS those dirs are mostly empty,
  # so every bare coreutils/awk/etc. invocation fails with "command not
  # found". Set an explicit PATH at the top of every script we generate.
  # /run/current-system/sw/bin gives us cosmic-randr.
  scriptPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.util-linux
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.procps
    pkgs.systemd
    pkgs.lsof
    pkgs.drm_info
    pkgs.gnutar
    pkgs.gdb
  ];

  # Shared dump body — invoked by the system-sleep hook (with phase
  # pre|post) and by the manual `suspend-capture` command (phase manual).
  # Args: $1 = pre|post|manual   $2 = cycle-id (timestamp dir name)
  dumpScript = pkgs.writeShellScript "suspend-debug-dump" ''
    set -u
    export PATH="${scriptPath}:/run/current-system/sw/bin"
    PHASE="$1"
    CYCLE="$2"
    OUT="${cfg.logRoot}/$CYCLE/$PHASE"
    mkdir -p "$OUT"

    # --- /sys/power scalars ---
    for f in /sys/power/mem_sleep /sys/power/wakeup_count \
             /sys/power/pm_wakeup_irq /sys/power/pm_debug_messages \
             /sys/power/pm_print_times; do
      [ -r "$f" ] && cp -L "$f" "$OUT/$(basename "$f")" 2>/dev/null || true
    done

    # --- /sys/power/suspend_stats (kernel-version-dependent layout) ---
    if [ -d /sys/power/suspend_stats ]; then
      for f in /sys/power/suspend_stats/*; do
        [ -r "$f" ] || continue
        name=$(basename "$f")
        cat "$f" > "$OUT/suspend_stats.$name" 2>/dev/null || true
      done
    fi

    # --- DRM connectors (per-card, per-connector) ---
    for c in /sys/class/drm/card*-*; do
      [ -d "$c" ] || continue
      cn=$(basename "$c")
      for fld in enabled status modes dpms; do
        [ -r "$c/$fld" ] && cat "$c/$fld" > "$OUT/$cn.$fld" 2>/dev/null || true
      done
    done

    # --- GPU device PM state ---
    for d in /sys/class/drm/card*/device; do
      [ -d "$d" ] || continue
      cn=$(basename "$(dirname "$d")")
      for fld in power_state power/control power/runtime_status \
                 power/runtime_suspended_time; do
        ff="$d/$fld"
        [ -r "$ff" ] || continue
        out_name=$(echo "$fld" | tr '/' '_')
        cat "$ff" > "$OUT/$cn.dev.$out_name" 2>/dev/null || true
      done
    done

    # --- debugfs / amdgpu state (the most useful files) ---
    # Allowlist by directory shape and file basename. /sys/kernel/debug/dri/
    # contains both the GPU root (PCI BDF dir like 0000:c1:00.0) and per-DRM
    # -client folders (client-N) that have a `device` symlink back to the GPU
    # root — naive recursion into client-N/device/ lands on trigger files
    # like amdgpu_gfxoff that block on read. Plus 1/, 128/ are symlinks back
    # to the same GPU root (duplicate work). Restrict carefully.
    if [ -d /sys/kernel/debug/dri ]; then
      for d in /sys/kernel/debug/dri/*/; do
        idx=$(basename "$d")
        # Only PCI BDF roots (e.g. 0000:c1:00.0). Skips symlinks (1, 128) and
        # client-N/.
        case "$idx" in
          *:*:*.*) ;;
          *) continue ;;
        esac
        # Belt and suspenders: skip if the dir entry itself is a symlink.
        [ -L "''${d%/}" ] && continue

        # Root-level files: explicit allowlist of cheap, non-triggering ones.
        # `clients` + `internal_clients` show DRM master ownership — the key
        # evidence for cosmic-comp #2191 (DRM master / lease desync on resume).
        for af in state clients internal_clients name \
                  amdgpu_firmware_info amdgpu_discovery \
                  amdgpu_dm_dprx_states amdgpu_dm_psr_capability \
                  amdgpu_dm_capabilities amdgpu_dm_dmub_fw_state \
                  amdgpu_dm_ips_status amdgpu_dm_dtn_log; do
          [ -r "$d/$af" ] || continue
          timeout 2 cat "$d/$af" > "$OUT/dri.$idx.$af" 2>/dev/null || true
        done

        # Per-connector / CRTC / encoder subdirs only.
        for cdir in "$d"*/; do
          cname=$(basename "$cdir")
          case "$cname" in
            crtc-*|DP-*|eDP-*|HDMI-*|encoder-*) ;;
            *) continue ;;
          esac
          for ff in "$cdir"*; do
            [ -f "$ff" ] || continue
            bn=$(basename "$ff")
            # Skip known-blocking / state-mutating entries.
            case "$bn" in
              *trigger*|*force*|*hpd*|*test_*) continue ;;
            esac
            timeout 1 cat "$ff" > "$OUT/dri.$idx.$cname.$bn" 2>/dev/null || true
            # If the cat timed out we may have a 0- or oversize file.
            sz=$(stat -c%s "$OUT/dri.$idx.$cname.$bn" 2>/dev/null || echo 0)
            [ "$sz" -gt 65536 ] && rm -f "$OUT/dri.$idx.$cname.$bn"
          done
        done
      done
    fi

    # --- Compositor / Xwayland process state ---
    for proc in cosmic-comp cosmic-session cosmic-greeter Xwayland \
                xdg-desktop-portal-cosmic; do
      pids=$(${pkgs.procps}/bin/pidof -- "$proc" 2>/dev/null || true)
      for pid in $pids; do
        {
          echo "=== $proc pid=$pid ==="
          cat /proc/"$pid"/status 2>/dev/null
          echo "--- wchan ---"
          cat /proc/"$pid"/wchan 2>/dev/null; echo
          echo "--- stack ---"
          cat /proc/"$pid"/stack 2>/dev/null
          echo "--- fds ---"
          ls -l /proc/"$pid"/fd 2>/dev/null
        } > "$OUT/proc.$proc.$pid" 2>/dev/null || true
      done
    done

    # --- Output topology via cosmic-randr (best-effort, time-bounded) ---
    # cosmic-comp does not implement wlr-output-management; cosmic-randr
    # is the right tool. From a system-sleep hook we have no Wayland
    # socket of our own, so reach into the user session.
    USER_UID=1000
    RUNTIME_DIR="/run/user/$USER_UID"
    if [ -d "$RUNTIME_DIR" ]; then
      WL_SOCK=$(ls "$RUNTIME_DIR"/wayland-* 2>/dev/null | head -1 | xargs -n1 -r basename)
      if [ -n "$WL_SOCK" ]; then
        timeout 3 ${pkgs.util-linux}/bin/runuser -u ngarvey -- \
          env XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WL_SOCK" \
          /run/current-system/sw/bin/cosmic-randr list \
          > "$OUT/cosmic-randr.list" 2>&1 || true
      fi
    fi

    # --- drm_info (JSON): every CRTC/plane/connector and every property
    # value, including blob property IDs (MODE_ID etc). If the
    # `pending.blob` staleness theory for cosmic-comp #2191 is right, the
    # post-resume snapshot will reference a blob ID the kernel no longer
    # knows about.
    timeout 3 ${pkgs.drm_info}/bin/drm_info -j > "$OUT/drm_info.json" 2>&1 || true

    # --- libseat / logind session activation state ---
    timeout 3 ${pkgs.systemd}/bin/loginctl seat-status seat0 \
      > "$OUT/loginctl-seat-status.txt" 2>&1 || true
    timeout 3 ${pkgs.systemd}/bin/loginctl list-sessions \
      >> "$OUT/loginctl-seat-status.txt" 2>&1 || true

    # --- DRM fd holders ---
    timeout 3 ${pkgs.lsof}/bin/lsof /dev/dri/card1 /dev/dri/renderD128 \
      > "$OUT/lsof-dri.txt" 2>&1 || true

    # --- Recent kernel log + journal (post / manual phase only) ---
    case "$PHASE" in
      post|manual)
        ${pkgs.util-linux}/bin/dmesg -T > "$OUT/dmesg.full" 2>&1 || true
        ${pkgs.systemd}/bin/journalctl -b -k --since "5 minutes ago" \
          > "$OUT/journal-kernel.log" 2>&1 || true
        ${pkgs.systemd}/bin/journalctl -b --since "5 minutes ago" \
          -t cosmic-comp -t cosmic-session -t cosmic-greeter \
          -t cosmic-greeter-daemon -t Xwayland \
          -t org.freedesktop.impl.portal.desktop.cosmic \
          > "$OUT/journal-cosmic.log" 2>&1 || true
        ;;
    esac

    # --- Disk cap: evict oldest dated cycles until under maxBytes ---
    LIMIT_KB=$((${toString cfg.maxBytes} / 1024))
    while :; do
      cur=$(du -sk "${cfg.logRoot}" 2>/dev/null | awk '{print $1}')
      [ -z "$cur" ] && break
      [ "$cur" -le "$LIMIT_KB" ] && break
      oldest=$(ls -1tr "${cfg.logRoot}" 2>/dev/null | grep -v '^manual$' | head -1)
      [ -z "$oldest" ] && break
      rm -rf "${cfg.logRoot}/$oldest"
    done

    exit 0
  '';

  # Thin wrapper that systemd-sleep invokes. Establishes a stable cycle id
  # so pre/post end up in the same directory.
  hookScript = pkgs.writeShellScript "suspend-debug-hook" ''
    set -u
    export PATH="${scriptPath}:/run/current-system/sw/bin"
    [ "$2" = "suspend" ] || exit 0
    if [ "$1" = "pre" ]; then
      date -u +%Y%m%dT%H%M%SZ > /run/suspend-debug-current-cycle
    fi
    CYCLE=$(cat /run/suspend-debug-current-cycle 2>/dev/null \
            || date -u +%Y%m%dT%H%M%SZ)
    exec ${dumpScript} "$1" "$CYCLE"
  '';

  captureScript = pkgs.writeShellScriptBin "suspend-capture" ''
    set -u
    export PATH="${scriptPath}:/run/current-system/sw/bin"
    if [ "$(id -u)" -ne 0 ]; then
      exec sudo -E "$0" "$@"
    fi
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    OUT_DIR="${cfg.logRoot}/$TS"
    mkdir -p "$OUT_DIR/manual"

    echo "Running snapshot dump..." >&2
    ${dumpScript} manual "$TS"

    echo "Collecting gdb backtraces..." >&2
    for proc in cosmic-comp cosmic-session cosmic-greeter Xwayland \
                xdg-desktop-portal-cosmic; do
      for pid in $(${pkgs.procps}/bin/pidof -- "$proc" 2>/dev/null); do
        timeout 15 ${pkgs.gdb}/bin/gdb --batch -p "$pid" \
          -ex "set pagination off" \
          -ex "thread apply all bt" \
          > "$OUT_DIR/manual/gdb.$proc.$pid" 2>&1 || true
      done
    done

    TARBALL="${cfg.logRoot}/manual/suspend-capture-$TS.tar.gz"
    ${pkgs.gnutar}/bin/tar -C "${cfg.logRoot}" -czf "$TARBALL" "$TS" \
      && rm -rf "$OUT_DIR"
    echo "Wrote $TARBALL" >&2
  '';
in
{
  # No `enable` option: importing this module unconditionally activates the
  # whole instrumentation. Removing the experiment is then a one-line revert
  # in the host config (drop the import). Sub-options below are *behavior*
  # tuning, not on/off.
  options.suspendDebug = {
    enableDrmDebug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add drm.debug=0x6 (DRIVER + KMS) to kernel cmdline. Floods dmesg —
        only flip on once we've reproduced and want a deeper trace.
      '';
    };

    enableCosmicTrace = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set RUST_LOG=cosmic_comp=debug,smithay=debug,smithay::backend::drm=trace
        and RUST_BACKTRACE=full system-wide via environment.variables. The
        vars propagate into cosmic-comp's environ (greetd-spawned session).
        Most non-cosmic Rust tools ignore RUST_LOG, so noise is bounded.
      '';
    };

    logRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/suspend-debug";
      description = "Where snapshot dumps land.";
    };

    maxBytes = lib.mkOption {
      type = lib.types.int;
      default = 512 * 1024 * 1024;
      description = "Disk-usage cap; oldest dated cycles evicted first.";
    };
  };

  config = {
    # 1. systemd-sleep hook. NixOS has no typed option for this; the
    # idiomatic mechanism is dropping into /etc/systemd/system-sleep/.
    environment.etc."systemd/system-sleep/00-suspend-debug" = {
      source = hookScript;
      mode = "0755";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.logRoot}        0750 root wheel - -"
      "d ${cfg.logRoot}/manual 0750 root wheel - -"
      # Make sure PM debug stays on every boot, regardless of cmdline.
      "w /sys/power/pm_debug_messages - - - - 1"
      "w /sys/power/pm_print_times    - - - - 1"
    ];

    # 2. Kernel debug knobs. Existing list-typed boot.kernelParams in the
    # host config merges with these.
    boot.kernelParams = [
      "no_console_suspend"
      "pm_debug_messages"
    ] ++ lib.optional cfg.enableDrmDebug "drm.debug=0x6";
    boot.kernel.sysctl."kernel.sysrq" = 1;

    # 3. Compositor tracing — cosmic-comp is *not* a systemd user service
    # (it's a child of cosmic-session under greetd, in a session scope).
    # Empirically, environment.variables propagates into its environ
    # (EDITOR=nvim from nixos-common.nix is visible there), so use it.
    environment.variables = lib.mkIf cfg.enableCosmicTrace {
      RUST_LOG = "cosmic_comp=debug,smithay=debug,smithay::backend::drm=trace";
      RUST_BACKTRACE = "full";
    };

    services.journald.extraConfig = ''
      SystemMaxUse=4G
      MaxRetentionSec=2week
    '';

    # 4. Manual capture command for use from a TTY.
    environment.systemPackages = [ captureScript ];
  };
}
