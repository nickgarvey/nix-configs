{ config, lib, pkgs, ... }:

# Local audio transcription via faster-whisper (CTranslate2). On hosts
# with `nixpkgs.config.cudaSupport = true` the bundled torch/ctranslate2
# build links CUDA and uses the GPU automatically. Otherwise the same
# command runs on CPU.
#
# Provides:
#   whisper-gpu <audio> <out-prefix> [model]
#       Transcribe a local audio file. Writes <out-prefix>.txt and
#       <out-prefix>.vtt with `[HH:MM:SS.mmm --> HH:MM:SS.mmm]` lines.
#       Default model: large-v3.
#
#   yt-whisper <youtube-url> <out-prefix> [model]
#       Download audio from a YouTube URL with yt-dlp, then transcribe.
#       Cleans up the intermediate WAV.

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    faster-whisper
    ctranslate2
  ]);

  # The actual transcription logic, kept as its own file for readability
  # and easy editing. Same script we used in the lena-city-council-book
  # workflow, minus the LD_LIBRARY_PATH workaround (not needed under
  # nixpkgs cudaSupport).
  transcribeScript = pkgs.writeText "whisper-transcribe.py" ''
    #!/usr/bin/env python3
    """Transcribe an audio file with faster-whisper. Auto-detects GPU.
    Writes <prefix>.txt and <prefix>.vtt with timestamped segments."""
    import sys, time, datetime
    import ctranslate2
    from faster_whisper import WhisperModel

    audio = sys.argv[1]
    prefix = sys.argv[2]
    model_size = sys.argv[3] if len(sys.argv) > 3 else "large-v3"

    if ctranslate2.get_cuda_device_count() > 0:
        device, compute_type = "cuda", "float16"
    else:
        device, compute_type = "cpu", "int8"

    t0 = time.time()
    print(f"[{datetime.datetime.now():%H:%M:%S}] loading {model_size} on {device} ({compute_type})", flush=True)
    model = WhisperModel(model_size, device=device, compute_type=compute_type)
    print(f"[{datetime.datetime.now():%H:%M:%S}] model loaded in {time.time()-t0:.1f}s; transcribing {audio}", flush=True)

    segments, info = model.transcribe(
        audio,
        language="en",
        beam_size=5,
        vad_filter=True,
        vad_parameters=dict(min_silence_duration_ms=500),
    )
    print(f"[{datetime.datetime.now():%H:%M:%S}] duration {info.duration:.1f}s, lang prob {info.language_probability:.2f}", flush=True)

    def fmt(t):
        h, rem = divmod(int(t), 3600)
        m, s = divmod(rem, 60)
        ms = int((t - int(t)) * 1000)
        return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"

    txt = open(f"{prefix}.txt", "w")
    vtt = open(f"{prefix}.vtt", "w")
    vtt.write("WEBVTT\n\n")

    last_log = time.time()
    for seg in segments:
        line = seg.text.strip()
        txt.write(f"[{fmt(seg.start)} --> {fmt(seg.end)}]  {line}\n")
        vtt.write(f"{fmt(seg.start)} --> {fmt(seg.end)}\n{line}\n\n")
        txt.flush(); vtt.flush()
        if time.time() - last_log > 30:
            pct = seg.end / info.duration * 100 if info.duration else 0
            print(f"[{datetime.datetime.now():%H:%M:%S}] at audio t={seg.end:.0f}s ({pct:.1f}%)", flush=True)
            last_log = time.time()

    txt.close(); vtt.close()
    print(f"[{datetime.datetime.now():%H:%M:%S}] done in {time.time()-t0:.1f}s", flush=True)
  '';

  whisper-gpu = pkgs.writeShellApplication {
    name = "whisper-gpu";
    runtimeInputs = [ pythonEnv ];
    text = ''
      if [ "$#" -lt 2 ]; then
        echo "usage: whisper-gpu <audio-file> <out-prefix> [model]" >&2
        echo "  default model: large-v3 (others: base.en, small.en, medium.en, large-v3-turbo)" >&2
        exit 64
      fi
      exec python3 ${transcribeScript} "$@"
    '';
  };

  yt-whisper = pkgs.writeShellApplication {
    name = "yt-whisper";
    runtimeInputs = [ pkgs.yt-dlp pkgs.ffmpeg pythonEnv ];
    text = ''
      if [ "$#" -lt 2 ]; then
        echo "usage: yt-whisper <youtube-url> <out-prefix> [model]" >&2
        exit 64
      fi
      url="$1"
      prefix="$2"
      model="''${3:-large-v3}"
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      echo "[yt-whisper] downloading audio..."
      yt-dlp -x --audio-format wav \
        --postprocessor-args "-ar 16000 -ac 1" \
        -o "$tmpdir/audio.%(ext)s" "$url"
      echo "[yt-whisper] transcribing..."
      python3 ${transcribeScript} "$tmpdir/audio.wav" "$prefix" "$model"
    '';
  };
in
{
  environment.systemPackages = [ whisper-gpu yt-whisper ];
}
