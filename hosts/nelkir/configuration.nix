{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    ./hardware-configuration.nix
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ../../modules/core/nixos-common.nix
    ../../modules/networking/network-manager.nix
  ];

  networking.hostName = "nelkir";

  # This Pi lives at the TV on wifi, joined interactively with nmcli and
  # persisted by NetworkManager. Its lan-hosts entry carries the wifi MAC, so
  # the DHCP static lease and DNS record follow wlan0.

  # We dd the image directly; no need to spend build time on zstd compression.
  sdImage.compressImage = false;

  # vector-agent.nix arrives transitively via nixos-common.nix and has no enable
  # option of its own. Host metrics are not worth a Vector process on a Pi that
  # does one thing.
  services.vector.enable = lib.mkForce false;

  # The CEC userspace. cec-ctl/cec-follower/cec-compliance come from v4l-utils;
  # libcec's cec-client drives the same /dev/cec* Linux CEC framework devices.
  # The kernel side needs nothing: nixpkgs sets DRM_VC4_HDMI_CEC on aarch64.
  environment.systemPackages = with pkgs; [
    v4l-utils
    libcec
  ];

  # /dev/cec* are created root-owned with no group access, so CEC would need
  # sudo. Hand them to `video`, which ngarvey is in.
  #
  # The TV is an LG C2 on HDMI0 (physical address 3.0.0.0, i.e. TV input 3);
  # a Yamaha YAS-209 soundbar sits on the same bus at 2.0.0.0 over ARC.
  services.udev.extraRules = ''
    SUBSYSTEM=="cec", KERNEL=="cec[0-9]*", GROUP="video", MODE="0660"
  '';
  users.users.ngarvey.extraGroups = [ "video" ];


  # The TV drops back to its own speakers whenever ARC renegotiates (power
  # cycle, input change, soundbar standby). Nothing re-asserts it, so this
  # watches and puts audio back on the soundbar.
  #
  # Mechanism: SYSTEM_AUDIO_MODE_REQUEST is a request to the audio system, not
  # a command to the TV. The soundbar answers by broadcasting
  # SET_SYSTEM_AUDIO_MODE on, and the TV mutes its own speakers in response.
  # phys-addr is whose audio to render -- 0.0.0.0 is the TV, i.e. over ARC.
  #
  # The adapter keeps its logical address across cec-ctl invocations, so the
  # LA is claimed once at start and the poll loop reuses it instead of
  # re-announcing itself on the bus every few seconds.
  systemd.services.cec-audio-guard =
    let
      cecAudioGuard = pkgs.writeShellScript "cec-audio-guard" ''
        set -u
        PATH=${lib.makeBinPath [ pkgs.v4l-utils pkgs.gnugrep pkgs.gawk pkgs.coreutils ]}

        # cec node numbering follows the HDMI controller, so it moves if the
        # cable moves ports. Pick whichever has negotiated a real physical
        # address (f.f.f.f means no EDID / nothing plugged in).
        DEV=""
        for d in /dev/cec*; do
          pa=$(cec-ctl -d "$d" 2>/dev/null | awk '/Physical Address/ { print $NF; exit }')
          if [ -n "$pa" ] && [ "$pa" != "f.f.f.f" ]; then DEV="$d"; break; fi
        done
        if [ -z "$DEV" ]; then
          echo "no cec device with a physical address; is the TV connected?" >&2
          exit 1
        fi
        echo "using $DEV"

        # Claim a logical address once; later polls inherit it.
        cec-ctl -d "$DEV" --playback >/dev/null 2>&1

        misses=0
        while true; do
          status=$(cec-ctl -d "$DEV" --to 5 --give-system-audio-mode-status 2>/dev/null \
                     | awk '/sys-aud-status/ { print $2; exit }')

          if [ -z "$status" ]; then
            # No answer: soundbar asleep or bus quiet. Tolerate a few, then let
            # systemd restart us so the device is re-detected (e.g. port moved).
            misses=$((misses + 1))
            [ "$misses" -ge 20 ] && { echo "audio system unreachable" >&2; exit 1; }
          else
            misses=0
            if [ "$status" = "off" ]; then
              # Only assert while the TV is actually on, so this never wakes
              # the soundbar for a TV that someone deliberately turned off.
              tv=$(cec-ctl -d "$DEV" --to 0 --give-device-power-status 2>/dev/null \
                     | awk '/pwr-state/ { print $2; exit }')
              if [ "$tv" = "on" ]; then
                echo "system audio off while TV is on -- reasserting soundbar"
                cec-ctl -d "$DEV" --to 5 --system-audio-mode-request phys-addr=0.0.0.0 >/dev/null 2>&1
              fi
            fi
          fi
          sleep 3
        done
      '';
    in
    {
      description = "Keep TV audio on the soundbar over HDMI-CEC";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        ExecStart = cecAudioGuard;
        Restart = "always";
        RestartSec = 10;
        DynamicUser = true;
        SupplementaryGroups = [ "video" ];   # /dev/cec* are root:video 0660
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

  # Stop the TV being pulled out of standby (and switched to this input) every
  # time the Pi reboots -- the firmware sends a CEC active-source message at
  # HDMI init. This is NOT hdmi_ignore_cec: CEC stays fully enabled, so
  # powering the TV on deliberately and cec-audio-guard both keep working.
  #
  # config.txt is generated by sdImage.populateFirmwareCommands, which is an
  # untyped option and so cannot be merged -- overriding it to add one line
  # would mean owning a verbatim copy of upstream's whole DTB block, which goes
  # stale silently. Instead append to the config.txt already written into the
  # image. postBuildCommands is types.lines so this merges, and writing to $img
  # here is its documented purpose. Offset derived with partx exactly as
  # sd-image.nix does, rather than assuming firmwarePartitionOffset.
  sdImage.postBuildCommands = ''
    eval $(partx "$img" -o START,SECTORS --nr 1 --pairs)
    fw="$img@@$((START * 512))"

    mcopy -o -i "$fw" ::/config.txt ./config.txt
    {
      echo ""
      echo "# Do not send the initial CEC active-source message at HDMI init."
      echo "hdmi_ignore_cec_init=1"
    } >> ./config.txt
    mcopy -o -i "$fw" ./config.txt ::/config.txt
  '';

  # Boot tuning for a headless appliance.
  #
  # The extlinux menu timeout defaults to 5s, which is a flat third of this
  # Pi's boot. 1s rather than 0 so an older generation can still be picked at
  # the TV if a deploy goes bad -- otherwise recovery means pulling the card.
  boot.loader.timeout = 1;
  boot.loader.generic-extlinux-compatible.configurationLimit = 10;

  # hardware.bluetooth.enable = false only governs userspace; the kernel still
  # probes the DT-declared BT UART and spends ~12s failing to talk to it
  # ("BCM: failed to write update baudrate (-110)"). This lands after
  # multi-user.target so it does not delay sshd, but nothing here uses
  # Bluetooth, so keep it off the bus entirely.
  boot.blacklistedKernelModules = [ "hci_uart" "btbcm" "btqca" ];

  system.stateVersion = "25.11";
}
