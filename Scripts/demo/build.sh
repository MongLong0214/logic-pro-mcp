#!/usr/bin/env bash
# Re-render the launch film from the recorded take. Everything except the live recording is scripted here.
#
#   build.sh process     raw/film.mov + out/film.jsonl -> JPEG frame sequence, session.json
#   build.sh render      Remotion: 4K silent masters (launch + social), then the per-frame dropout scan
#   build.sh audio       bed + sound design + EQ + loudness -> work/final*.wav
#   build.sh encode      every deliverable, each mapped explicitly to the mastered audio
#   build.sh check       hard gate on every output: audio stream present, loudness, true peak, dropout scan
#   build.sh all         process, render, audio, encode, check
#
# Inputs (written by record_take.sh): raw/film.mov raw/film.meta.json out/film.jsonl. Outputs land in out/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p raw/footage work out
LUFS_TARGET="${LUFS_TARGET:--14}"
TP_TARGET="${TP_TARGET:--1.6}"  # headroom: AAC and Opus add inter-sample peaks, the delivered files must stay at or under -1.0 dBTP
PORT="${FOOTAGE_PORT:-8765}"
SEQ_START_S=1.1   # first footage second extracted (the film opens at footage 1.15)

stage_process() {
  ffmpeg -y -hide_banner -loglevel error -i raw/film.mov -vn -ac 2 -ar 48000 -c:a pcm_s16le raw/film.audio.wav
  rm -rf raw/footage/film && mkdir -p raw/footage/film
  local start_frame
  start_frame=$(python3 -c "print(round($SEQ_START_S*60))")
  ffmpeg -y -hide_banner -loglevel error -ss "$SEQ_START_S" -i raw/film.mov -vf fps=60 -q:v 3 -start_number "$start_frame" raw/footage/film/%05d.jpg
  python3 align.py --log out/film.jsonl --meta raw/film.meta.json --video raw/film.mov --audio raw/film.audio.wav \
    --seq film --seq-start "$start_frame" --out motion/public/data/session.json "$@"
}

serve_footage() {
  (cd raw/footage && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  SERVER_PID=$!
  trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
  sleep 1
  export REMOTION_FOOTAGE_BASE="http://127.0.0.1:$PORT"
}

stage_render() {
  [ -d motion/node_modules ] || (cd motion && npm ci --no-audit --no-fund)
  serve_footage
  export REMOTION_MOTION_BLUR="${MOTION_BLUR:-1}"
  local scale=2 conc="${CONCURRENCY:-6}"
  [ "${PREVIEW:-0}" = 1 ] && { scale=0.5; export REMOTION_MOTION_BLUR=0; }
  # --muted: the masters carry no audio track; the mastered audio is mapped in at encode time
  for comp in Launch Social; do
    local out="../work/$(echo $comp | tr 'A-Z' 'a-z').silent.mp4"
    (cd motion && npx remotion render src/index.ts "$comp" "$out" --scale="$scale" --concurrency="$conc" --crf=14 --codec=h264 --image-format=png --muted)
    python3 scan_frames.py "work/$(echo $comp | tr 'A-Z' 'a-z').silent.mp4"
  done
}

loudnorm_pass() { # $1 in.wav  $2 out.wav
  local m mi mtp mlra mth off
  m=$(ffmpeg -hide_banner -nostats -i "$1" -af "loudnorm=I=$LUFS_TARGET:TP=$TP_TARGET:LRA=7:print_format=json" -f null - 2>&1 | sed -n '/^{/,/^}/p')
  mi=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_i"])')
  mtp=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_tp"])')
  mlra=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_lra"])')
  mth=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_thresh"])')
  off=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_offset"])')
  ffmpeg -y -hide_banner -loglevel error -i "$1" -af "loudnorm=I=$LUFS_TARGET:TP=$TP_TARGET:LRA=7:measured_I=$mi:measured_TP=$mtp:measured_LRA=$mlra:measured_thresh=$mth:offset=$off:linear=true" -ar 48000 -c:a pcm_s24le "$2"
}

# The song's own balance as captured: the patch is sub-heavy and dull. Mastering for phones and laptops:
# high-pass, bass cut, presence and air, then glue compression and a limiter before the loudness normalisation.
MASTER_CHAIN="highpass=f=38,equalizer=f=60:t=q:w=0.8:g=-8,equalizer=f=120:t=q:w=1:g=-4,equalizer=f=3500:t=q:w=1:g=2.5,treble=g=4:f=7000,acompressor=threshold=-36dB:ratio=3:attack=30:release=350:makeup=7,alimiter=limit=0.9:attack=5:release=80"

stage_audio() {
  node --experimental-strip-types motion/scripts/export-cues.mjs > work/cues.json 2>/dev/null
  local onset
  onset=$(python3 -c 'import json;print(json.load(open("motion/public/data/session.json"))["film"]["musicStart"])')
  # the bed is Logic's own output of the song, captured digitally during the take, starting on bar 1
  ffmpeg -y -hide_banner -loglevel error -ss "$onset" -i raw/film.audio.wav -t 50 -ac 2 -ar 48000 -c:a pcm_s16le work/bed.wav
  python3 sound_design.py --cues work/cues.json --bed work/bed.wav --out work/mix.wav
  python3 sound_design.py --cues work/cues.json --bed work/bed.wav --out work/mix.social.wav --social
  for f in mix mix.social; do
    ffmpeg -y -hide_banner -loglevel error -i work/$f.wav -af "$MASTER_CHAIN" -c:a pcm_s16le work/$f.lim.wav
  done
  loudnorm_pass work/mix.lim.wav work/final.wav
  loudnorm_pass work/mix.social.lim.wav work/final.social.wav
  python3 qa_audio.py work/final.wav | tee out/audio-qa.json || true
  python3 qa_audio.py work/final.social.wav | tee out/audio-qa.social.json || true
}

# BT.709 everywhere; web files get a 2 s GOP so seeking in the site player is quick.
COLOR=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -x264-params colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv)
COLOR_NOX=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)
SCALE709="scale=1920:1080:flags=lanczos:out_color_matrix=bt709,format=yuv420p"

stage_encode() {
  local V=work/launch.silent.mp4 S=work/social.silent.mp4 A=work/final.wav SA=work/final.social.wav
  local aac=(-c:a aac -b:a 256k -ar 48000)
  local map=(-map 0:v:0 -map 1:a:0)
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -c:v copy "${COLOR_NOX[@]}" "${aac[@]}" -movflags +faststart out/logic-pro-mcp-launch-4k.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -vf "$SCALE709" -c:v libx264 -preset slow -crf 21 -profile:v high -r 60 -g 120 -keyint_min 120 "${COLOR[@]}" "${aac[@]}" -movflags +faststart out/logic-pro-mcp-demo.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -vf "$SCALE709,fps=30" -c:v libx264 -preset slow -crf 24 -maxrate 6M -bufsize 12M -profile:v high -g 60 -keyint_min 60 "${COLOR[@]}" -c:a aac -b:a 160k -ar 48000 -movflags +faststart out/logic-pro-mcp-demo-web.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -vf "$SCALE709,fps=30" -c:v libvpx-vp9 -b:v 0 -crf 34 -row-mt 1 -cpu-used 2 -g 60 "${COLOR_NOX[@]}" -c:a libopus -b:a 128k out/logic-pro-mcp-demo-web.webm
  ffmpeg -y -hide_banner -loglevel error -i $S -i $SA "${map[@]}" -vf "$SCALE709" -c:v libx264 -preset slow -crf 21 -r 60 -g 120 "${COLOR[@]}" "${aac[@]}" -movflags +faststart out/logic-pro-mcp-demo-social.mp4
  # README GIF: the social cut's picture, silent by nature, starting on a lit frame (frame 0 is the finished headline)
  ffmpeg -y -hide_banner -loglevel error -i $S -vf "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=112:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" out/logic-pro-mcp-demo.gif
  # posters: the finished headline frame, and a frame where the hook's fader is on screen
  local t_hook
  t_hook=$(python3 -c 'import json;print(json.load(open("work/cues.json"))["P"]+20.6)')
  ffmpeg -y -hide_banner -loglevel error -ss "$t_hook" -i $V -frames:v 1 -vf "scale=1920:1080:flags=lanczos" out/poster-1080.png
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1280:720:flags=lanczos out/logic-pro-mcp-thumbnail.png
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1024:576:flags=lanczos work/p1024.png && cwebp -quiet -q 72 work/p1024.png -o out/session-poster.webp
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=660:371:flags=lanczos work/p660.png && cwebp -quiet -q 72 work/p660.png -o out/session-poster-660.webp
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1024:576:flags=lanczos out/session-poster.png
}

stage_check() {
  local fail=0
  mkdir -p work/qa
  for f in out/logic-pro-mcp-launch-4k.mp4 out/logic-pro-mcp-demo.mp4 out/logic-pro-mcp-demo-web.mp4 out/logic-pro-mcp-demo-web.webm out/logic-pro-mcp-demo-social.mp4; do
    local n; n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | wc -l | tr -d ' ')
    if [ "$n" -lt 1 ]; then echo "FAIL $f: no audio stream"; fail=1; continue; fi
    local wav="work/qa/$(basename "$f").wav"
    ffmpeg -y -hide_banner -loglevel error -i "$f" -map 0:a:0 -ac 2 -ar 48000 -c:a pcm_s24le "$wav"
    local rep; rep=$(python3 qa_audio.py "$wav" || true)
    local lufs tp; lufs=$(echo "$rep" | python3 -c 'import json,sys;print(json.load(sys.stdin)["integrated_lufs"])'); tp=$(echo "$rep" | python3 -c 'import json,sys;print(json.load(sys.stdin)["true_peak_dbtp"])')
    echo "$f  audio streams=$n  LUFS=$lufs  true-peak=$tp  $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate:format=duration -of csv=p=0 "$f" | tr '\n' ' ')"
    python3 - "$lufs" "$tp" "$f" <<'PY' || fail=1
import sys
lufs, tp, f = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
if lufs < -30: sys.exit(f"FAIL {f}: {lufs} LUFS is below -30 (silent audio)")
if abs(lufs + 14) > 1.5: sys.exit(f"FAIL {f}: {lufs} LUFS is not near -14")
if tp > -1.0: sys.exit(f"FAIL {f}: true peak {tp} dBTP")
PY
  done
  python3 scan_frames.py work/launch.silent.mp4 || fail=1
  python3 scan_frames.py work/social.silent.mp4 || fail=1
  python3 qa_audio.py work/final.wav > out/audio-qa.json || fail=1
  cat out/audio-qa.json
  [ "$fail" = 0 ] && echo "BUILD CHECK PASS" || { echo "BUILD CHECK FAIL"; exit 1; }
}

case "${1:-all}" in
  process) shift; stage_process "$@" ;;
  render) stage_render ;;
  audio) stage_audio ;;
  encode) stage_encode ;;
  check) stage_check ;;
  all) stage_process; stage_render; stage_audio; stage_encode; stage_check ;;
  *) echo "usage: build.sh process|render|audio|encode|check|all" >&2; exit 2 ;;
esac
