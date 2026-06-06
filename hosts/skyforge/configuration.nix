{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    ../../modules/nixos-common.nix
    ../../modules/networkd.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "skyforge";

  # We dd the image directly; no need to spend build time on zstd compression.
  sdImage.compressImage = false;

  # Cross-compile the whole closure: buildPlatform x86_64 → hostPlatform
  # aarch64 (set in hardware-configuration.nix). Most of nixpkgs cross-builds
  # cleanly; the kernel is the big win. If a specific package fails to cross,
  # override it back to emulated with a per-package overlay:
  #   nixpkgs.overlays = [(final: prev: {
  #     # forces foo to build via binfmt instead of cross
  #     foo = (final.pkgsBuildBuild.callPackage (prev.path + "/pkgs/.../foo") {});
  #   })];
  # Cross-compile JUST the kernel (the long pole). Everything else stays on
  # binfmt emulation. Whole-closure cross (nixpkgs.buildPlatform = x86)
  # works for many packages but breaks parade-of-fails on Go (git-lfs -m64),
  # Lua-codegen at build time (neovim), and probably more — for one printer
  # host the constant overrides aren't worth it.
  #
  # nvmd's raspberry-pi-5/default.nix sets boot.kernelPackages from its own
  # flake outputs (`nixos-raspberrypi.packages.aarch64-linux.linuxPackages_rpi5`),
  # so even mkForce'ing pkgs.linuxPackages_rpi5 from a native context still
  # gives a native kernel. We sidestep entirely: re-import nvmd's nixpkgs
  # with crossSystem set and reapply nvmd's overlays, then use that one
  # package. Adds one extra nixpkgs eval but only this drv is affected.
  boot.kernelPackages = let
    crossPkgs = import inputs.nixos-raspberrypi.inputs.nixpkgs {
      localSystem = "x86_64-linux";
      crossSystem = "aarch64-linux";
      overlays = with inputs.nixos-raspberrypi.overlays; [
        bootloader
        vendor-kernel
        vendor-firmware
        kernel-and-firmware
        vendor-pkgs
      ];
    };
  in lib.mkForce crossPkgs.linuxPackages_rpi5;

  # Hard-wired ethernet; no WiFi. The IP layer comes from networkd.nix
  # (DHCPv4 + static IPv6 via systemd-networkd, matched by MAC from
  # lan-hosts.nix).
  homelab.network.enable = true;

  # Pi 5: nixos-hardware raspberry-pi-5 module enables
  # boot.loader.generic-extlinux-compatible; NVMe-first boot order is in the
  # Pi's EEPROM (already set on this unit).

  # Klipper config layout: nix ships read-only fragments under /etc/klipper/,
  # and a tiny wrapper printer.cfg is seeded once into
  # /var/lib/moonraker/config/ so SAVE_CONFIG can append calibration
  # (bed_mesh, scanner models, PID, input_shaper) without nix clobbering
  # it on rebuild. Edits to fragments propagate on the next klipper restart.
  # State lives under moonraker's unified data dir so moonraker's
  # file_manager finds printer.cfg in its expected `config/` location.
  environment.etc = {
    "klipper/main.cfg".source = ./klipper/main.cfg;
    "klipper/mainsail.cfg".source = ./klipper/mainsail.cfg;
    "klipper/macros.cfg".source = ./klipper/macros.cfg;
    "klipper/start.cfg".source = ./klipper/start.cfg;
    "klipper/nozzle_scrubber.cfg".source = ./klipper/nozzle_scrubber.cfg;
    "klipper/filament_sensor.cfg".source = ./klipper/filament_sensor.cfg;
  };

  # The nixos klipper module only sets restartTriggers when mutableConfig=false.
  # We use mutableConfig=true (so SAVE_CONFIG survives), but still want a deploy
  # that changes a nix-managed fragment to restart klipper — otherwise klippy
  # keeps the old config in memory until manual restart. Mid-print deploys will
  # interrupt; don't deploy mid-print.
  # The NixOS moonraker module copies /etc/moonraker.cfg → moonraker-temp.cfg
  # in an ExecStart script and never sets restartTriggers, so config changes
  # land on disk but the running process keeps the old settings until manual
  # restart. Trigger off the /etc template so deploys actually take effect.
  systemd.services.moonraker.restartTriggers = [
    config.environment.etc."moonraker.cfg".source
  ];

  systemd.services.klipper.restartTriggers = [
    config.environment.etc."klipper/main.cfg".source
    config.environment.etc."klipper/mainsail.cfg".source
    config.environment.etc."klipper/macros.cfg".source
    config.environment.etc."klipper/start.cfg".source
    config.environment.etc."klipper/nozzle_scrubber.cfg".source
    config.environment.etc."klipper/filament_sensor.cfg".source
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/moonraker/config 0755 klipper klipper - -"
    "d /var/lib/moonraker/gcodes 0755 klipper klipper - -"
  ];

  # Stock klipper doesn't ship the Cartographer V3 probe plugin. Build the
  # official cartographer3d-plugin python package (hatchling/hatch-vcs, so
  # we pretend a version since the nix source has no .git), then wire it
  # into klipper's python env via extraPythonPackages and drop the
  # scaffolding stub that klipper's plugin loader expects at
  # klippy/extras/cartographer.py (its single line re-exports
  # cartographer.extra). Upstream install.sh does the same two-step.
  services.klipper = let
    pluginVersion = "1.6.0";
    cartographer3dPlugin = pkgs.python3.pkgs.buildPythonPackage {
      pname = "cartographer3d-plugin";
      version = pluginVersion;
      src = inputs.cartographer3d-plugin;
      format = "pyproject";
      nativeBuildInputs = (with pkgs.python3.pkgs; [ hatchling hatch-vcs typing-extensions ])
        ++ [ pkgs.git ];  # hatch_build.py shells out to git unconditionally
      propagatedBuildInputs = with pkgs.python3.pkgs; [ typing-extensions ];
      env = {
        # hatch-vcs / setuptools_scm version detection without .git
        SETUPTOOLS_SCM_PRETEND_VERSION = pluginVersion;
        # Plugin's custom hatch build hook reads these in CI guard mode
        GIT_VERSION = "v${pluginVersion}";
        COMMIT_SHA = "0000000000000000000000000000000000000000";
      };
      doCheck = false;
    };
  in {
    enable = true;
    user = "klipper";
    group = "klipper";
    mutableConfig = true;
    configDir = "/var/lib/moonraker/config";
    configFile = ./printer-seed.cfg;
    firmwares = { };
    package = (pkgs.klipper.override {
      extraPythonPackages = ps: [ cartographer3dPlugin ];
    }).overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        echo "from cartographer.extra import *" > $out/lib/klipper/extras/cartographer.py
      '';
    });
  };

  services.moonraker = {
    enable = true;
    user = "klipper";
    group = "klipper";
    allowSystemControl = true;
    address = "::";
    port = 7125;
    settings = {
      # Omitting [authorization] does NOT disable auth — moonraker loads
      # the authorization component by default and defaults trusted_clients
      # to []. Result: every request 401s. Explicitly trust everything
      # since this is LAN/Tailscale-only with no public exposure.
      authorization = {
        cors_domains = [ "*" ];
        trusted_clients = [ "0.0.0.0/0" "::/0" ];
      };
      octoprint_compat = { };
      history = { };
      "webcam Cam1" = {
        location = "printer";
        service = "mjpegstreamer-adaptive";
        target_fps = 15;
        stream_url = "http://skyforge.home.arpa:8080/stream";
        snapshot_url = "http://skyforge.home.arpa:8080/snapshot";
      };
    };
  };

  services.ustreamer = {
    enable = true;
    device = "/dev/video0";
    listenAddress = "[::]:8080";
    extraArgs = [
      "--resolution=1920x1080"
      "--desired-fps=60"
      "--format=MJPEG"
      "--allow-origin=*"
    ];
  };

  # ustreamer's internal retry loop gives up after a single EPERM, which it
  # hits at boot because it opens /dev/video0 before udev finishes applying
  # the `video` group perms. Block startup until the device is actually
  # openable from the service's runtime user/group context. Can't use
  # dev-video0.device ordering — V4L2 devices aren't tagged with `systemd`
  # by default, so that unit never activates and dependents time out.
  systemd.services.ustreamer.serviceConfig.ExecStartPre = [
    (pkgs.writeShellScript "wait-video0" ''
      for i in $(seq 1 60); do
        [ -r /dev/video0 ] && exit 0
        sleep 0.5
      done
      exit 1
    '')
  ];

  services.mainsail = {
    enable = true;
    hostName = "skyforge.home.arpa";
  };

  # The mainsail module builds its nginx upstream as `${moonraker.address}:${port}`,
  # which produces an unbracketed `:::7125` when moonraker listens on `::`. Override
  # to a bracketed v6 loopback so nginx parses it correctly.
  services.nginx.upstreams.mainsail-apiserver.servers = lib.mkForce {
    "[::1]:7125" = {};
  };

  # Default nginx client_max_body_size (1M) rejects large gcode uploads with 413.
  services.nginx.clientMaxBodySize = "2G";

  networking.firewall.allowedTCPPorts = [ 80 7125 8080 ];

  services.tailscale.enable = true;

  security.polkit.enable = true;

  users.users.klipper = {
    isSystemUser = true;
    group = "klipper";
    extraGroups = [ "dialout" "tty" ];
  };
  users.groups.klipper = { };

  system.stateVersion = "25.11";
}
