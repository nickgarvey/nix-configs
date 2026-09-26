{ config, lib, pkgs, inputs, ... }:

let
  helium-browser = pkgs.callPackage ../../pkgs/helium-browser {
    helium-browser-pkg = inputs.helium-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };
  claude-code = inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  codex = inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  thinkrail = inputs.thinkrail.packages.${pkgs.stdenv.hostPlatform.system}.thinkrail;
  agent-issue-tracker = pkgs.callPackage ../../pkgs/agent-issue-tracker { };

  # Waybar kanata button (configs/waybar/config.jsonc, custom/kanata). The
  # status script prints the button state; the restart script marks the button
  # "restarting" (yellow) and pokes waybar via SIGRTMIN+8 (the module's
  # "signal": 8) so the colour changes immediately rather than on the next poll.
  kanataRestartMarker = ''"''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kanata-restarting"'';
  kanata-waybar-status = pkgs.writeShellApplication {
    name = "kanata-waybar-status";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils ];
    text = ''
      state=$(systemctl is-active kanata-keyboard.service || true)
      if [ -e ${kanataRestartMarker} ] || [[ $state =~ ^(activating|deactivating|reloading)$ ]]; then
        class=restarting tooltip="kanata restarting…"
      elif [ "$state" = active ]; then
        class=active tooltip="kanata running (click to restart)"
      else
        class=failed tooltip="kanata $state (click to restart)"
      fi
      printf '{"text": "⌨", "class": "%s", "tooltip": "%s"}\n' "$class" "$tooltip"
    '';
  };
  kanata-restart = pkgs.writeShellApplication {
    name = "kanata-restart";
    runtimeInputs = [ pkgs.systemd pkgs.procps pkgs.coreutils ];
    text = ''
      marker=${kanataRestartMarker}
      refresh() { pkill -RTMIN+8 waybar || true; }
      trap 'rm -f "$marker"; refresh' EXIT
      touch "$marker"
      refresh
      /run/wrappers/bin/sudo -n ${pkgs.systemd}/bin/systemctl restart kanata-keyboard.service
      # Wait for kanata to come back up (up to 10s), and keep the button
      # yellow for at least a second so a fast restart is still visible.
      sleep 1
      for _ in $(seq 18); do
        systemctl is-active --quiet kanata-keyboard.service && break
        sleep 0.5
      done
    '';
  };
in
{
  imports = [
    ../core/nixos-common.nix
    ./printer.nix
    ./orca-slicer.nix
    ./steam.nix
    ../services/smb-automount.nix
    ../home/ngarvey.nix
    ../llms/hf-to-garage.nix
    ../llms/pi.nix
    inputs.sops-nix.nixosModules.sops
  ];

  # Manual HuggingFace → garage llm-models bucket upload tool.
  homelab.hfToGarage.enable = true;

  # pi coding agent for the ngarvey user.
  homelab.pi.enable = true;

  # Workstation peripheral udev rules (rules for absent devices are inert).
  # Keychron: allow VIA / Keychron Launcher (WebHID) without root.
  #   3434 - Keychron vendor ID; GROUP="users" + TAG+="uaccess" for seat access.
  # Vial: match on the Vial magic serial (vendor-agnostic) so the Vial GUI can
  #   reach any Vial-firmware keyboard's hidraw node without root. qmk-udev-rules
  #   only covers bootloader/DFU flashing, not this runtime hidraw access.
  # Keebio: FoldKB (cb10) runs VIA firmware; grant hidraw access for the VIA app.
  # Pico: unprivileged access to RP2040 in BOOTSEL mode (2e8a) and pico-dirtyJtag (1209:c0ca).
  # ESP-Prog-2: Espressif USB JTAG adapter (303a:1002).
  # FoldKB joystick misdetection: the FoldKB's "System Control" interface exposes
  #   ABS axes, so input_id tags it ID_INPUT_JOYSTICK=1. SDL2 then enumerates the
  #   keyboard as a gamepad, and its resting axis reads as a constant direction
  #   (e.g. breaks rightward movement in Baba Is You). Clear the tag; it is not a
  #   joystick. 99-local.rules runs after input_id, so this override wins.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", ATTRS{idVendor}=="3434", MODE="0660", GROUP="users", TAG+="uaccess"
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{serial}=="*vial:f64c2b3c*", MODE="0660", GROUP="users", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="cb10", MODE="0660", GROUP="users", TAG+="uaccess"
    SUBSYSTEM=="input", ATTRS{idVendor}=="cb10", ATTRS{idProduct}=="2358", ENV{ID_INPUT_JOYSTICK}=""
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="c0ca", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1002", MODE="0666"
  '';

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [ "split_lock_detect=off" ];

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  nixpkgs.config.allowUnfree = true;

  # Wrap Chrome to always pass --hide-crash-restore-bubble
  nixpkgs.overlays = [
    (self: super: {
      google-chrome = super.google-chrome.override {
        commandLineArgs = "--hide-crash-restore-bubble";
      };
    })
  ];

  # Audio
  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
  ];

  # Enable Wayland for Chrome and VSCode
  environment.variables.NIXOS_OZONE_WL = "1";

  time.timeZone = "America/Los_Angeles";

  users.users.ngarvey = {
    uid = 1000;
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "render" "dialout" "tty" "input" "docker" ];
    packages = with pkgs; [
      agent-issue-tracker # `ait`, a local-first issue tracker for coding agents
      android-tools # adb/fastboot for Android debugging
      # Sync server: https://anki.home.garvey.sh/ (enter in Preferences → Syncing;
      # SYNC_ENDPOINT is ignored by the desktop client).
      (anki.withAddons (with ankiAddons; [ anki-connect ]))
      atop
      beads
      claude-code
      codex
      dig
      dmidecode
      efibootmgr
      gh
      ghostty
      google-chrome
      helium-browser
      htop
      incus
      k9s
      kubectl
      libnotify
      mpv
      obsidian
      parallel
      ripgrep
      spotify
      thinkrail
      virt-viewer
      wl-clipboard
    ];
  };

  # Tailscale DNS is off (--accept-dns=false below): home names resolve from
  # public DNS, and LAN DNS keeps working when the tailnet does not.
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "false";
  };
  networking.networkmanager.dns = "systemd-resolved";

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-dns=false"
      "--operator=ngarvey"
      "--exit-node-allow-lan-access"
    ];
  };

  networking.firewall = {
    allowedUDPPorts = [
      5353 # Spotify Connect
    ];
    # Disable firewall logging to prevent dmesg spam from port scans
    logRefusedConnections = false;
  };

  services.xserver.enable = true;

  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    enableOnBoot = true;
  };

  services.kanata = {
    enable = true;
    keyboards.keyboard = {
      configFile = ../../configs/kanata-linux.cfg;
      extraDefCfg = "process-unmapped-keys yes";
    };
  };

  environment.systemPackages = [ kanata-waybar-status kanata-restart ];

  systemd.services.kanata-keyboard.serviceConfig = {
    Restart = "on-failure";
    RestartSec = 3;
  };

  systemd.user.settings.Manager.DefaultTimeoutStopSec = "10s";
}

