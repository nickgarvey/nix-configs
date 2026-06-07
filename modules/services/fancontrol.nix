{ pkgs, ... }:
let
  fanctl = pkgs.writers.writePython3 "lydia-fanctl" {
    # Disable all flake8 checks; we are not interested in style enforcement
    # for an embedded script.
    flakeIgnore = [ "E1" "E2" "E3" "E4" "E5" "E7" "W" ];
  } ''
    import glob
    import os
    import signal
    import sys
    import time

    POLL_SEC = 5

    # (label, min_temp_c, max_temp_c, min_pwm, max_pwm)
    CURVES = {
        "pwm1": ("CPU fan",     45.0, 85.0, 80, 255),
        "pwm2": ("chassis fan", 50.0, 90.0, 80, 255),
    }

    def find_f71882fg_dir():
        matches = glob.glob("/sys/devices/platform/f71882fg.*")
        if not matches:
            sys.exit("f71882fg platform device not found")
        return matches[0]

    def find_coretemp_pkg_input():
        for h in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
            try:
                with open(os.path.join(h, "name")) as f:
                    if f.read().strip() != "coretemp":
                        continue
            except FileNotFoundError:
                continue
            for label_path in glob.glob(os.path.join(h, "temp*_label")):
                with open(label_path) as f:
                    if f.read().strip() == "Package id 0":
                        return label_path.replace("_label", "_input")
        sys.exit("coretemp Package id 0 not found")

    def read_int(path):
        with open(path) as f:
            return int(f.read().strip())

    def write_int(path, v):
        with open(path, "w") as f:
            f.write(str(v))

    def curve(temp_c, tmin, tmax, pmin, pmax):
        if temp_c <= tmin:
            return pmin
        if temp_c >= tmax:
            return pmax
        frac = (temp_c - tmin) / (tmax - tmin)
        return int(round(pmin + frac * (pmax - pmin)))

    def restore_auto(sio):
        for name in CURVES:
            try:
                write_int(os.path.join(sio, f"{name}_enable"), 2)
            except Exception as e:
                print(f"restore {name}: {e}", flush=True)
        print("restored BIOS auto mode", flush=True)

    def main():
        sio = find_f71882fg_dir()
        cpu_pkg = find_coretemp_pkg_input()
        print(f"sio={sio}", flush=True)
        print(f"temp source={cpu_pkg}", flush=True)

        # Manual mode
        for name in CURVES:
            write_int(os.path.join(sio, f"{name}_enable"), 1)

        def on_sig(signum, _frame):
            restore_auto(sio)
            sys.exit(0)
        signal.signal(signal.SIGTERM, on_sig)
        signal.signal(signal.SIGINT, on_sig)

        last_pwm = {}
        while True:
            t_milli = read_int(cpu_pkg)
            t_c = t_milli / 1000.0
            for name, (label, tmin, tmax, pmin, pmax) in CURVES.items():
                pwm = curve(t_c, tmin, tmax, pmin, pmax)
                if last_pwm.get(name) != pwm:
                    write_int(os.path.join(sio, name), pwm)
                    rpm = read_int(os.path.join(sio, f"fan{name[-1]}_input"))
                    print(f"{label}: cpu={t_c:.1f}C -> {name}={pwm} (rpm={rpm})", flush=True)
                    last_pwm[name] = pwm
            time.sleep(POLL_SEC)

    main()
  '';
in
{
  systemd.services.lydia-fanctl = {
    description = "lydia fan curve controller (f71882fg / F81866A)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${fanctl}";
      Restart = "on-failure";
      RestartSec = 5;
      # Best-effort restore to BIOS auto curve if the unit stops or fails.
      ExecStopPost = pkgs.writeShellScript "lydia-fanctl-stop" ''
        for d in /sys/devices/platform/f71882fg.*; do
          [ -e "$d/pwm1_enable" ] && echo 2 > "$d/pwm1_enable" || true
          [ -e "$d/pwm2_enable" ] && echo 2 > "$d/pwm2_enable" || true
        done
      '';
    };
  };
}
