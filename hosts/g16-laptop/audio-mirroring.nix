{ config, lib, pkgs, ... }:

{
  # Audio mirroring: mirrors audio between USB devices only
  systemd.user.services.pipewire-audio-mirror = {
    description = "Setup audio mirroring between multiple devices";
    wantedBy = [ "pipewire-pulse.service" ];
    after = [ "pipewire-pulse.service" ];
    path = with pkgs; [ pulseaudio coreutils gnugrep gnused gawk ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for PipeWire and USB devices to be fully initialized
      ${pkgs.coreutils}/bin/sleep 5

      setup_combined_sink() {
        PACTL=pactl
        $PACTL unload-module module-combine-sink 2>/dev/null || true

        SINKS=$($PACTL list short sinks | \
          ${pkgs.gnugrep}/bin/grep "usb-" | \
          ${pkgs.gnugrep}/bin/grep -v "combined" | \
          ${pkgs.gnugrep}/bin/grep -v "null" | \
          ${pkgs.gawk}/bin/awk '{print $2}')

        if [ -z "$SINKS" ]; then
          return 1
        fi

        SINK_COUNT=$(echo "$SINKS" | ${pkgs.coreutils}/bin/wc -l | ${pkgs.gnused}/bin/sed 's/^[[:space:]]*//')

        if [ "$SINK_COUNT" -ge 2 ]; then
          SINK_LIST=$(echo "$SINKS" | ${pkgs.gnused}/bin/sed 's/$/,/g' | ${pkgs.coreutils}/bin/tr -d '\n' | ${pkgs.gnused}/bin/sed 's/,$//')
          $PACTL load-module module-combine-sink sink_name=combined_sink slaves="$SINK_LIST" || true
          $PACTL set-default-sink combined_sink || true

          # Wait a moment for sinks to be ready, then normalize volumes
          ${pkgs.coreutils}/bin/sleep 1

          # Normalize volumes: boost Logitech device (quieter) relative to Pixel buds
          for SINK in $SINKS; do
            if echo "$SINK" | ${pkgs.gnugrep}/bin/grep -q "Logitech"; then
              # Boost Logitech by ~6dB (approximately 1.5x volume, or 150%)
              $PACTL set-sink-volume "$SINK" 150% 2>/dev/null || true
            elif echo "$SINK" | ${pkgs.gnugrep}/bin/grep -q "Pixel"; then
              # Keep Pixel buds at 100% as reference
              $PACTL set-sink-volume "$SINK" 100% 2>/dev/null || true
            fi
          done
          return 0
        fi
        return 1
      }

      # Retry up to 5 times with increasing delays
      for i in 1 2 3 4 5; do
        if setup_combined_sink; then
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done
    '';
  };

  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "setup-audio-mirror" ''
      #!/usr/bin/env bash
      pactl unload-module module-combine-sink 2>/dev/null || true

      SINKS=$(pactl list short sinks | grep "usb-" | grep -v "combined" | grep -v "null" | awk '{print $2}')
      SINK_COUNT=$(echo "$SINKS" | grep -c . || echo "0")

      if [ "$SINK_COUNT" -lt 2 ]; then
        echo "Error: Need at least 2 audio devices. Found: $SINK_COUNT"
        echo "Available sinks:"
        pactl list short sinks
        exit 1
      fi

      SINK_LIST=$(echo "$SINKS" | sed 's/$/,/g' | tr -d '\n' | sed 's/,$//')
      pactl load-module module-combine-sink sink_name=combined_sink slaves="$SINK_LIST"
      pactl set-default-sink combined_sink

      sleep 1

      # Normalize volumes: boost Logitech device (quieter) relative to Pixel buds
      for SINK in $SINKS; do
        if echo "$SINK" | grep -q "Logitech"; then
          pactl set-sink-volume "$SINK" 150% 2>/dev/null || true
        elif echo "$SINK" | grep -q "Pixel"; then
          pactl set-sink-volume "$SINK" 100% 2>/dev/null || true
        fi
      done

      echo "Audio mirroring enabled. Output will be sent to:"
      echo "$SINKS" | sed 's/^/  - /'
    '')
  ];
}
