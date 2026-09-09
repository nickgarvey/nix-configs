# A one-command-per-connection CEC socket, so hosts without a CEC adapter can
# drive the TV. CEC is a physical bus with no network protocol of its own, and
# a PC HDMI output exposes no /dev/cec*, so the only machine that can talk to
# the TV is the one actually wired to it.
#
# The transport is a systemd socket unit rather than HTTP: one connection is
# one verb, so there is nothing for HTTP to add beyond a request parser.
#   printf 'standby\n' | nc nelkir 5555   ->  OK
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.cecControl;

  cecPath = lib.makeBinPath [ pkgs.v4l-utils pkgs.gawk pkgs.coreutils ];

  handler = pkgs.writeShellScript "cec-control-handler" ''
    set -u
    PATH=${cecPath}

    # systemd sets REMOTE_ADDR for Accept=yes sockets. Enforcing the allowlist
    # here rather than in the firewall keeps it working whichever backend the
    # host uses; the port is still open, so this is an access check, not a
    # perimeter.
    allow="${lib.concatStringsSep " " cfg.allowedSources}"
    if [ -n "$allow" ]; then
      permitted=0
      for a in $allow; do
        [ "$a" = "''${REMOTE_ADDR:-}" ] && permitted=1
      done
      if [ "$permitted" != 1 ]; then
        echo "ERR forbidden"
        exit 0
      fi
    fi

    # While the TV is in standby the HDMI link can drop, and the adapter loses
    # its physical address -- so strict detection fails exactly when you want
    # to wake the TV. Fall back to the first node and try anyway; a transmit
    # that genuinely cannot be addressed still reports ERR below.
    DEV=$(${cfg.pickDevice}) || DEV=$(ls /dev/cec* 2>/dev/null | head -1)
    if [ -z "$DEV" ]; then echo "ERR no-cec-device"; exit 0; fi

    read -r verb arg || verb=""
    verb=$(printf '%s' "$verb" | tr -cd 'a-z')
    arg=$(printf '%s' "''${arg:-}" | tr -cd '0-9a-fA-F.')

    case "$verb" in
      standby)
        # The TV only honours STANDBY from whatever it currently considers the
        # active source, so claim that first. Without this the transmit
        # succeeds and the TV simply ignores it -- which looks like the command
        # working. The momentary input switch is invisible because the TV goes
        # dark immediately after, and `wake` routes back here on the way up.
        # Claim the caller's input as active source, not ours: the TV both
        # honours STANDBY only from the active source and resumes on whatever
        # was active when it slept. Asserting our own input here would put the
        # TV to sleep on the Pi and wake it there.
        WANT="$arg"
        case "$WANT" in
          [0-9a-fA-F].[0-9a-fA-F].[0-9a-fA-F].[0-9a-fA-F]) ;;
          *) WANT=$(cec-ctl -d "$DEV" 2>/dev/null \
                      | awk '/Physical Address/ { print $NF; exit }') ;;
        esac
        if [ -n "$WANT" ] && [ "$WANT" != "f.f.f.f" ]; then
          cec-ctl -d "$DEV" --active-source phys-addr="$WANT" >/dev/null 2>&1
          sleep 1
        fi

        # Tell cec-audio-guard to stand down briefly. The TV keeps reporting
        # "on" for several seconds after STANDBY, so the guard would otherwise
        # see a live TV, poke the soundbar, and the soundbar's
        # SET_SYSTEM_AUDIO_MODE broadcast would wake the TV straight back up.
        mkdir -p /run/cec-control 2>/dev/null
        date +%s > /run/cec-control/standby-at 2>/dev/null
        cec-ctl -d "$DEV" --to 0 --standby >/dev/null 2>&1 && echo OK || echo ERR
        ;;
      on)
        # image-view-on is the wake counterpart to standby; active-source then
        # asks the TV to actually switch to whoever sent it.
        cec-ctl -d "$DEV" --to 0 --image-view-on >/dev/null 2>&1 && echo OK || echo ERR
        ;;
      source)
        # Ask the TV to route to a given HDMI input. Set Stream Path is a
        # broadcast any device may send, so nelkir can point the TV at a port
        # it is not itself plugged into.
        case "$arg" in
          [0-9a-fA-F].[0-9a-fA-F].[0-9a-fA-F].[0-9a-fA-F]) ;;
          *) echo "ERR bad phys-addr"; exit 0 ;;
        esac
        # Set Stream Path alone is not enough on wake: the TV broadcasts
        # REQUEST_ACTIVE_SOURCE, this adapter's own CEC stack answers with its
        # physical address, and the TV routes to the Pi instead. Claim Active
        # Source on the caller's behalf as well, and again after a moment to
        # win against that reply.
        cec-ctl -d "$DEV" --set-stream-path phys-addr="$arg" >/dev/null 2>&1
        cec-ctl -d "$DEV" --active-source phys-addr="$arg" >/dev/null 2>&1
        sleep 2
        cec-ctl -d "$DEV" --active-source phys-addr="$arg" >/dev/null 2>&1 \
          && echo OK || echo ERR
        ;;
      status)
        s=$(cec-ctl -d "$DEV" --to 0 --give-device-power-status 2>/dev/null \
              | awk '/pwr-state/ { print $2; exit }')
        echo "''${s:-unknown}"
        ;;
      *)
        echo "ERR usage: standby [a.b.c.d]|on|status|source <a.b.c.d>"
        ;;
    esac
  '';
in
{
  options.homelab.cecControl = {
    enable = lib.mkEnableOption "the CEC command socket";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5555;
      description = "TCP port the CEC command socket listens on.";
    };

    allowedSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.28.1.11" ];
      description = ''
        Source addresses permitted to issue commands, matched against
        systemd's REMOTE_ADDR. Empty means any host that can reach the port.
      '';
    };

    pickDevice = lib.mkOption {
      type = lib.types.path;
      internal = true;
      description = ''
        Script printing the /dev/cec* node that has negotiated a real physical
        address. Shared with cec-audio-guard so both agree on which node is the
        TV: cec node numbering follows the HDMI controller, so it moves if the
        cable moves ports, and f.f.f.f means no EDID / nothing plugged in.
      '';
    };
  };

  config = {
    homelab.cecControl.pickDevice = pkgs.writeShellScript "cec-pick-device" ''
      PATH=${cecPath}
      for d in /dev/cec*; do
        pa=$(cec-ctl -d "$d" 2>/dev/null | awk '/Physical Address/ { print $NF; exit }')
        if [ -n "$pa" ] && [ "$pa" != "f.f.f.f" ]; then
          echo "$d"
          exit 0
        fi
      done
      exit 1
    '';

    systemd.sockets.cec-control = lib.mkIf cfg.enable {
      description = "CEC command socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = toString cfg.port;
        Accept = true;
      };
    };

    # Instantiated per connection; stdin/stdout are the socket.
    systemd.services."cec-control@" = lib.mkIf cfg.enable {
      description = "CEC command for %I";
      serviceConfig = {
        ExecStart = handler;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        # Same access shape as cec-audio-guard: /dev/cec* are root:video 0660.
        DynamicUser = true;
        SupplementaryGroups = [ "video" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        # A wedged cec-ctl must not pin a connection open forever.
        TimeoutStartSec = 15;
        # Shared with cec-audio-guard, which reads the standby inhibit here.
        RuntimeDirectory = "cec-control";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.enable [ cfg.port ];
  };
}
