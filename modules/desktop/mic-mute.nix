# Workaround + diagnostics for the Arctis Nova Pro Wireless mic-mute fault.
#
# The mute is hardware-backed: PipeWire's input route for this card carries
# route.hw-mute = "true", so the source node's mute is bound directly to the USB
# Audio Class feature unit ("Mic Capture Switch", INV_BOOLEAN). Something
# asserts that control and nothing logs it, which silently breaks mic input in
# apps like Discord until manually unmuted.
#
# Two services, meant to run together:
#
#   autoUnmute — the workaround. Forces the default source unmuted every 5s.
#   monitor    — the diagnostic. Watches the control via `alsactl monitor`
#                (event-driven, no polling) and records the surrounding state
#                the instant it changes.
#
# They coexist deliberately: alsactl fires immediately, the unmute loop only
# reacts up to 5s later, so the snapshot lands in between and the mic keeps
# working during the capture window. Expect each mute in the log to be followed
# by the loop's unmute.
#
# The units are NixOS systemd.user.services rather than home-manager ones, since
# home-manager here manages config files only (see modules/home/ngarvey.nix).
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.audio.micMute;

  # This is temporary scaffolding, so make it expire rather than rot in the
  # tree. builtins.currentTime is unavailable under flake pure eval, and a
  # build-time check derivation would be cached after its first success and
  # never fire again, so key off the flake's own timestamp instead: the check
  # trips on the first rebuild whose commit lands after the deadline.
  deadline = 1793491200; # 2026-11-01T00:00:00Z
  flakeTime = lib.max inputs.self.lastModified inputs.nixpkgs.lastModified;

  # SteelSeries Arctis Nova Pro Wireless base station.
  usbId = "1038:12e0";
  control = "Mic Capture Switch";

  monitorScript = pkgs.writeShellScript "mic-mute-monitor" ''
    set -u
    export PATH=${lib.makeBinPath [
      pkgs.alsa-utils
      pkgs.wireplumber
      pkgs.libnotify
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
    ]}

    # The ALSA card index is not stable across reboots, so resolve it by usbid
    # rather than hardcoding. Retry: at boot this service can win the race
    # against the headset enumerating.
    card=""
    while [ -z "$card" ]; do
      for f in /proc/asound/card*/usbid; do
        [ -r "$f" ] || continue
        if [ "$(cat "$f")" = "${usbId}" ]; then
          card=$(basename "$(dirname "$f")")
          card=''${card#card}
          break
        fi
      done
      if [ -z "$card" ]; then
        echo "waiting for USB device ${usbId} to appear as an ALSA card"
        sleep 5
      fi
    done
    echo "watching '${control}' on card $card (hw:$card)"

    # Read the control element directly. `amixer get` only accepts simple-mixer
    # names ("Mic"), not element names, and its output mixes the volume's [on]
    # in with the switch's; cget yields a bare "on"/"off".
    # INV_BOOLEAN: "on" means capture enabled, i.e. NOT muted.
    hw_state() {
      amixer -c "$card" cget name="${control}" 2>/dev/null | sed -n 's/^  : values=//p'
    }

    last_notify=0

    # alsactl reports every control on the card; we only care about ours. Every
    # event on this element is a real toggle, so log unconditionally rather than
    # diffing against a previous reading: the unmute loop can flip the control
    # back within 5s, and a dedup on state would silently drop the mute we are
    # here to catch. Read hw_state first, before the slower snapshot commands,
    # to lose that race as rarely as possible.
    alsactl monitor "hw:$card" | grep --line-buffered -F "${control}" | while read -r event; do
      now=$(hw_state)

      # Snapshot everything that distinguishes the candidate causes: whether the
      # capture stream was open (device reset across open/close), what PipeWire
      # thinks (polarity disagreement), and who held the mic (software culprit).
      pw=$(wpctl get-volume @DEFAULT_SOURCE@ 2>&1)
      capture=$(awk '/^Capture:/{getline; print $2; exit}' "/proc/asound/card$card/stream0")
      # Scope to the Audio section: a bare '/Streams:/,$p' also swallows the
      # Video and Settings sections, which say nothing about who held the mic.
      streams=$(wpctl status 2>/dev/null \
        | sed -n '/^Audio/,/^Video/p' | sed -n '/Streams:/,$p' | head -n 20)

      if [ "$now" = "off" ]; then
        echo "MIC MUTED — hw=$now pipewire='$pw' capture-stream=$capture"
      else
        # Either a genuine unmute (usually mic-auto-unmute clearing the previous
        # line's mute) or a mute already cleared before we could read it.
        echo "mic unmuted — hw=$now pipewire='$pw' capture-stream=$capture"
      fi
      echo "  event: $event"
      echo "  streams: $(echo "$streams" | tr '\n' '|')"

      # Notify on the mute direction only, debounced so a flapping hardware
      # assert fighting the unmute loop cannot spam the notification daemon.
      if [ "$now" = "off" ]; then
        t=$(date +%s)
        if [ $((t - last_notify)) -ge 30 ]; then
          notify-send -u critical "Mic muted by hardware" \
            "capture-stream=$capture, pipewire=$pw" || true
          last_notify=$t
        fi
      fi
    done
  '';
in
{
  options.homelab.audio.micMute = {
    autoUnmute.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Continuously force the default PipeWire audio source unmuted, working
        around the headset's hardware mic-mute reaching OS-level mute.
      '';
    };

    monitor.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Log and notify whenever the headset's hardware mic-mute control changes
        state, to diagnose what is asserting it. Intended to run alongside
        autoUnmute, not instead of it. Read the results with
        `journalctl --user -u mic-mute-monitor -b`.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.autoUnmute.enable || cfg.monitor.enable) {
      assertions = [{
        assertion = flakeTime < deadline;
        message = ''
          homelab.audio.micMute expired on 2026-11-01: it is a temporary
          workaround plus diagnostic scaffolding for the Arctis mic-mute fault.
          Either the cause was found (delete modules/desktop/mic-mute.nix and
          its import and enable lines in hosts/wabbajack/configuration.nix), or
          it was not and the deadline in that module needs pushing out
          deliberately.
        '';
      }];
    })

    (lib.mkIf cfg.autoUnmute.enable {
      systemd.user.services.mic-auto-unmute = {
        description = "Continuously force-unmute the default PipeWire audio source";
        after = [ "pipewire.service" "wireplumber.service" ];
        wantedBy = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.bash}/bin/bash -c 'while true; do ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_SOURCE@ 0; sleep 5; done'";
          Restart = "always";
        };
      };
    })

    (lib.mkIf cfg.monitor.enable {
      environment.systemPackages = [ pkgs.alsa-utils ];

      systemd.user.services.mic-mute-monitor = {
        description = "Log hardware mic-mute transitions on the USB headset";
        after = [ "pipewire.service" "wireplumber.service" ];
        wantedBy = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = monitorScript;
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
  ];
}
