{ config, pkgs, ... }:
let
  mountDir = "/home/ngarvey/SeaDrive";
  dataDir = "/home/ngarvey/.seadrive/data";

  # Queries the running daemon over its libsearpc socket -- the same interface
  # seadrive-gui uses, which is what makes the GUI unnecessary here. Frame
  # format (libsearpc lib/searpc-named-pipe-transport.c): a native-endian uint32
  # length, then {"service":..., "request":"<json array [fname, args...]>"};
  # the reply is framed the same way and is {"ret":...} or {"err_code","err_msg"}.
  seadrive-status = pkgs.writers.writePython3Bin "seadrive-status" { flakeIgnore = [ "E501" ]; } ''
    import json
    import os
    import socket
    import struct
    import sys
    import time

    SEAF_DIR = os.path.expanduser("~/.seadrive/data")
    SOCK = os.path.join(SEAF_DIR, "seadrive.sock")
    CACHE_DIR = os.path.join(SEAF_DIR, "file-cache")
    SERVICE = "seadrive-rpcserver"

    # Cross-invocation scratch for the CPU delta and the cached du result.
    STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp",
                         "seadrive-status.state")

    # Fraction of one core above which the daemon counts as working. Measured
    # 2026-09-03 against the log's own state transitions: a 'committing' window
    # runs at ~99% of a core, while 'uploading' sits at ~2% because it is
    # network-bound. 0.2 is nowhere near either.
    BUSY_CPU = 0.2
    # A delta measured across a longer gap than this says nothing useful.
    MAX_SAMPLE_AGE = 60.0
    CACHE_TTL = 30.0
    CACHE_WALK_BUDGET = 0.5


    def call(sock, fname):
        body = json.dumps({"service": SERVICE, "request": json.dumps([fname])}).encode()
        sock.sendall(struct.pack("=I", len(body)) + body)
        (n,) = struct.unpack("=I", recv_exactly(sock, 4))
        reply = json.loads(recv_exactly(sock, n))
        if "err_code" in reply:
            raise RuntimeError("%s: %s" % (fname, reply.get("err_msg")))
        return reply.get("ret")


    def recv_exactly(sock, n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("daemon closed the connection")
            buf += chunk
        return buf


    def human(n):
        for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
            if abs(n) < 1024:
                return "%.1f %s" % (n, unit)
            n /= 1024.0
        return "%.1f PiB" % n


    def compact(n):
        """Narrow form for the bar, so the module does not jitter mid-transfer."""
        for unit in ("B", "K", "M", "G", "T"):
            if abs(n) < 1024:
                return "%.0f%s" % (n, unit) if unit == "B" else "%.1f%s" % (n, unit)
            n /= 1024.0
        return "%.1fP" % n


    def daemon_pid():
        """The pid file in SEAF_DIR is written empty, so scan /proc instead."""
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                with open("/proc/%s/comm" % entry) as f:
                    if f.read().strip() == "seadrive":
                        return int(entry)
            except OSError:
                continue
        return None


    def cpu_ticks(pid):
        with open("/proc/%d/stat" % pid) as f:
            data = f.read()
        # comm can contain spaces and parens, so split after the last ')'.
        rest = data[data.rindex(")") + 2:].split()
        return int(rest[11]) + int(rest[12])  # utime + stime


    def read_state():
        try:
            with open(STATE) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}


    def write_state(state):
        # Atomic: waybar polls every 2s and may race a hand-run invocation.
        tmp = "%s.%d" % (STATE, os.getpid())
        try:
            with open(tmp, "w") as f:
                json.dump(state, f)
            os.replace(tmp, STATE)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass


    def cache_bytes(state, now):
        """Walk the file-cache, at most every CACHE_TTL and never for long."""
        prev = state.get("cache")
        if prev and now - prev.get("t", 0) < CACHE_TTL:
            return prev.get("bytes")

        deadline = time.monotonic() + CACHE_WALK_BUDGET
        total = 0
        try:
            for root, _dirs, files in os.walk(CACHE_DIR):
                for name in files:
                    try:
                        total += os.lstat(os.path.join(root, name)).st_size
                    except OSError:
                        pass
                if time.monotonic() > deadline:
                    # Too big to measure cheaply; omit rather than stall the bar.
                    state["cache"] = {"bytes": None, "t": now}
                    return None
        except OSError:
            state["cache"] = {"bytes": None, "t": now}
            return None

        state["cache"] = {"bytes": total, "t": now}
        return total


    def busy_fraction(state, now):
        """CPU used by the daemon since the previous invocation, in cores.

        Returns None when it cannot be known -- no previous sample, a stale one,
        or a restarted daemon -- so the caller reports idle rather than guessing.
        """
        pid = daemon_pid()
        if pid is None:
            return None
        try:
            ticks = cpu_ticks(pid)
        except (OSError, ValueError, IndexError):
            return None

        prev = state.get("cpu")
        state["cpu"] = {"pid": pid, "ticks": ticks, "t": now}

        if not prev or prev.get("pid") != pid:
            return None
        elapsed = now - prev.get("t", 0)
        if elapsed <= 0 or elapsed > MAX_SAMPLE_AGE:
            return None

        hz = os.sysconf("SC_CLK_TCK")
        return (ticks - prev["ticks"]) / float(hz) / elapsed


    def describe(status):
        lines = [
            "state:       %s" % status.get("state", "?"),
            "auto sync:   %s" % ("on" if status.get("auto_sync_enabled") else "off"),
            "upload rate: %s/s" % human(status.get("sent_bytes", 0)),
        ]

        cache = status.get("cache_bytes")
        limit = status.get("cache_limit")
        if cache is not None:
            line = "cache:       %s" % human(cache)
            if limit:
                line += " (limit %s)" % human(limit)
            lines.append(line)

        progress = status["upload_progress"]

        # Note the key names: uploading_files / uploaded_files, not the
        # uploading / uploaded the arrays are called inside http-tx-mgr.c.
        uploading = progress.get("uploading_files") or []
        if uploading:
            lines += ["", "in flight (%d):" % len(uploading)]
            for f in uploading:
                total = f.get("total_upload") or 0
                done = f.get("uploaded") or 0
                pct = (100.0 * done / total) if total else 0.0
                lines.append("  %s  %.0f%% (%s / %s)" % (f.get("file_path", "?"), pct, human(done), human(total)))

        # uploading_files is only populated during the brief window a file is
        # actually on the wire, so on a fast LAN it is usually empty even right
        # after a large transfer. The recently-finished list is what a human
        # actually sees, so show it too.
        uploaded = progress.get("uploaded_files") or []
        if uploaded:
            lines += ["", "recently synced (%d):" % len(uploaded)]
            for f in uploaded[:5]:
                lines.append("  %s" % f.get("file_path", "?"))

        if status["sync_errors"]:
            lines += ["", "sync errors (%d):" % len(status["sync_errors"])]
            for e in status["sync_errors"]:
                lines.append("  %s: %s" % (e.get("path", "?"), e.get("err_msg", e)))

        return lines


    def main():
        args = sys.argv[1:]
        as_json = "--json" in args
        as_waybar = "--waybar" in args

        # One connection per call: the daemon closes the socket after replying.
        def q(fname):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(SOCK)
                return call(s, fname)

        try:
            # sent_bytes/recv_bytes are the bytes moved during the daemon's last
            # sampling interval, reset each tick -- so they are a throughput
            # sample, not a running total, and a short transfer can easily fall
            # between two polls. seafile_get_upload_rate returns the very same
            # field, so there is nothing to gain by also calling it. recv_bytes
            # is always 0: the line that would increment it is commented out
            # upstream in http-tx-mgr.c, so only the upload side is instrumented.
            status = q("seafile_get_global_sync_status")
            status["sync_errors"] = q("seafile_list_sync_errors") or []
            status["upload_progress"] = q("seafile_get_upload_progress") or {}
            status["cache_limit"] = q("seafile_get_cache_size_limit")
        # FileNotFoundError and ConnectionRefusedError are both OSError.
        except OSError as e:
            # waybar must always get valid JSON and a zero exit: on anything else
            # it blanks the module, which is indistinguishable from "idle" -- the
            # exact case this indicator exists to catch.
            if as_waybar:
                print(json.dumps({"text": "SEA off", "class": "stopped",
                                  "tooltip": "seadrive is not running"}))
                return 0
            print("cannot talk to seadrive: %s" % e, file=sys.stderr)
            return 1

        if as_json:
            print(json.dumps(status))
            return 0

        # is_syncing is true only while a repo is in SYNC_STATE_UPLOAD (or a file
        # fetch runs) -- see seaf_sync_manager_is_syncing in sync-mgr.c. It is
        # false throughout 'committing', which on a large backlog is minutes of
        # real work that would otherwise read as idle. The daemon does not expose
        # per-repo state at all, so infer that phase from its CPU use.
        now = time.time()
        state = read_state()
        cpu = busy_fraction(state, now)
        status["cache_bytes"] = cache_bytes(state, now)
        write_state(state)

        uploading = bool(status.get("is_syncing")) or bool(
            status["upload_progress"].get("uploading_files"))

        if status["sync_errors"]:
            status["state"] = "error"
        elif uploading:
            status["state"] = "uploading"
        elif cpu is not None and cpu >= BUSY_CPU:
            status["state"] = "busy (indexing)"
        else:
            status["state"] = "idle"

        if as_waybar:
            if status["state"] == "error":
                text, cls = "SEA !%d" % len(status["sync_errors"]), "error"
            elif status["state"] == "uploading":
                text, cls = "SEA %s/s" % compact(status.get("sent_bytes", 0)), "syncing"
            elif status["state"].startswith("busy"):
                text, cls = "SEA busy", "busy"
            else:
                text, cls = "SEA", "idle"
            print(json.dumps({"text": text, "class": cls,
                              "tooltip": "\n".join(describe(status))}))
            return 0

        print("\n".join(describe(status)))
        return 2 if status["sync_errors"] else 0


    sys.exit(main())
  '';
in
{
  # Headless SeaDrive. seadrive-fuse mounts seafile libraries on demand rather
  # than syncing them whole; seadrive-gui is deliberately not installed, since
  # it would keep the account credential in ~/.seadrive/accounts.db, outside
  # nix and sops, and would contend for the same mount point.
  environment.systemPackages = [ pkgs.seadrive-fuse seadrive-status ];

  # FUSE will not mount onto a path that does not exist, and seadrive only
  # mkdir's its log and dump dirs, never the mount point.
  systemd.tmpfiles.rules = [
    "d ${mountDir} 0755 ngarvey users -"
  ];

  sops.secrets.seadrive-token = {
    sopsFile = ../../secrets/seadrive.yaml;
    key = "seadrive_token_${config.networking.hostName}";
  };

  # One device token per host, so a machine can be unlinked server-side without
  # logging the others out. Owned by ngarvey because the daemon is a user
  # service; 0400 is safe because seadrive only ever reads this file
  # (load_account_from_file -> g_key_file_load_from_file, no save path).
  sops.templates."seadrive.conf" = {
    owner = "ngarvey";
    content = ''
      [account]
      server = https://seafile.home.garvey.sh
      username = garvey.nick@gmail.com
      token = ${config.sops.placeholder.seadrive-token}
      is_pro = true

      [general]
      client_name = ${config.networking.hostName}

      [cache]
      size_limit = 10GB
      clean_cache_interval = 10
    '';
  };

  systemd.user.services.seadrive = {
    description = "SeaDrive virtual drive client";
    # Tied to the user manager, not graphical-session: this is a daemon with no
    # UI. logind starts the user manager at first login and stops it at last
    # logout, so the drive is mounted exactly while ngarvey is logged in.
    wantedBy = [ "default.target" ];
    # seadrive execs fusermount, and only the setuid wrapper can mount.
    path = [ "/run/wrappers" pkgs.fuse ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.seadrive-fuse}/bin/seadrive \
          -c ${config.sops.templates."seadrive.conf".path} \
          -d ${dataDir} \
          -l /home/ngarvey/.seadrive/logs/seadrive.log \
          -f ${mountDir}
      '';
      # A crash otherwise leaves a stale mount that blocks the next start.
      ExecStopPost = "-/run/wrappers/bin/fusermount -u ${mountDir}";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
