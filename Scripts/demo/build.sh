#!/usr/bin/env bash
# Re-render the launch film from recorded takes. Everything except the live recording is scripted here.
#
#   build.sh process        raw/A.mov + raw/B.mov (+ driver logs) -> footage proxies, session.json, music bed
#   build.sh render         Remotion: 4K silent master + 26 s social cut (set PREVIEW=1 for a 540p draft)
#   build.sh audio          sound design + EBU R128 normalisation to -14 LUFS / -1 dBTP + QA report
#   build.sh encode         mp4 4K master, 1080p60 mp4, web mp4, webm, gif, posters
#   build.sh all            process, render, audio, encode
#
# Inputs (written by record_take.sh in the live session): raw/A.mov raw/B.mov raw/A.meta.json raw/B.meta.json
#   out/setup.jsonl out/play.jsonl. Outputs land in out/ (git-ignored except what publish.sh copies).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p raw/footage work out
LUFS_TARGET="${LUFS_TARGET:--14}"
TP_TARGET="${TP_TARGET:--1.0}"
PORT="${FOOTAGE_PORT:-8765}"

stage_process() {
  for t in A B; do
    ffmpeg -y -hide_banner -loglevel error -i "raw/$t.mov" -an -vf "fps=60" -c:v libx264 -preset medium -crf 12 -g 30 -pix_fmt yuv420p "raw/footage/$t.mp4"
  done
  ffmpeg -y -hide_banner -loglevel error -i raw/B.mov -vn -ac 2 -ar 48000 -c:a pcm_s16le raw/B.audio.wav
  python3 align.py --a-log out/setup.jsonl --a-meta raw/A.meta.json --a-video raw/footage/A.mp4 \
    --b-log out/play.jsonl --b-meta raw/B.meta.json --b-video raw/footage/B.mp4 --b-audio raw/B.audio.wav \
    --out motion/public/data/session.json "$@"
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
  (cd motion && npx remotion render src/index.ts Launch "../work/launch.silent.mp4" --scale="$scale" --concurrency="$conc" --crf=14 --codec=h264 --image-format=png)
  (cd motion && npx remotion render src/index.ts Social "../work/social.silent.mp4" --scale="$scale" --concurrency="$conc" --crf=14 --codec=h264 --image-format=png)
}

loudnorm_pass() { # $1 in.wav  $2 out.wav
  local m
  m=$(ffmpeg -hide_banner -nostats -i "$1" -af "loudnorm=I=$LUFS_TARGET:TP=$TP_TARGET:LRA=11:print_format=json" -f null - 2>&1 | sed -n '/^{/,/^}/p')
  local mi mtp mlra mth off
  mi=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_i"])')
  mtp=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_tp"])')
  mlra=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_lra"])')
  mth=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["input_thresh"])')
  off=$(echo "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_offset"])')
  ffmpeg -y -hide_banner -loglevel error -i "$1" -af "loudnorm=I=$LUFS_TARGET:TP=$TP_TARGET:LRA=11:measured_I=$mi:measured_TP=$mtp:measured_LRA=$mlra:measured_thresh=$mth:offset=$off:linear=true:print_format=summary" -ar 48000 -c:a pcm_s24le "$2"
}

stage_audio() {
  node --experimental-strip-types motion/scripts/export-cues.mjs > work/cues.json 2>/dev/null
  local total onset
  total=$(python3 -c 'import json;print(json.load(open("work/cues.json"))["total"])')
  onset=$(python3 -c 'import json;print(json.load(open("motion/public/data/session.json"))["takes"]["B"].get("audioOnset",0))')
  # the bed is Logic's own output of the song, captured digitally during take B, starting on the first note
  ffmpeg -y -hide_banner -loglevel error -ss "$onset" -i raw/B.audio.wav -t "$(python3 -c "print($total+3)")" -ac 2 -ar 48000 -c:a pcm_s16le work/bed.wav
  python3 sound_design.py --cues work/cues.json --bed work/bed.wav --out work/mix.wav
  python3 sound_design.py --cues work/cues.json --bed work/bed.wav --out work/mix.social.wav --social
  for f in mix mix.social; do
    ffmpeg -y -hide_banner -loglevel error -i work/$f.wav -af "acompressor=threshold=-26dB:ratio=2.2:attack=25:release=300:makeup=3,alimiter=limit=0.9:attack=5:release=60" -c:a pcm_s16le work/$f.lim.wav
  done
  loudnorm_pass work/mix.lim.wav work/final.wav
  loudnorm_pass work/mix.social.lim.wav work/final.social.wav
  python3 qa_audio.py work/final.wav | tee out/audio-qa.json
  python3 qa_audio.py work/final.social.wav | tee out/audio-qa.social.json || true
}

stage_encode() {
  local V=work/launch.silent.mp4 S=work/social.silent.mp4
  local aac=(-c:a aac -b:a 256k -ar 48000)
  # 4K master (kept local, too large for the repo)
  ffmpeg -y -hide_banner -loglevel error -i $V -i work/final.wav -c:v copy "${aac[@]}" -movflags +faststart out/logic-pro-mcp-launch-4k.mp4
  # 1080p60: the README / release mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i work/final.wav -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -preset slow -crf 21 -profile:v high -pix_fmt yuv420p -r 60 "${aac[@]}" -movflags +faststart out/logic-pro-mcp-demo.mp4
  # web-optimised: 1080p30 for the landing-site player
  ffmpeg -y -hide_banner -loglevel error -i $V -i work/final.wav -vf "scale=1920:1080:flags=lanczos,fps=30" -c:v libx264 -preset slow -crf 24 -maxrate 6M -bufsize 12M -profile:v high -pix_fmt yuv420p -c:a aac -b:a 160k -ar 48000 -movflags +faststart out/logic-pro-mcp-demo-web.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i work/final.wav -vf "scale=1920:1080:flags=lanczos,fps=30" -c:v libvpx-vp9 -b:v 0 -crf 34 -row-mt 1 -cpu-used 2 -pix_fmt yuv420p -c:a libopus -b:a 128k out/logic-pro-mcp-demo-web.webm
  # social + vertical-friendly 16:9 short cut
  ffmpeg -y -hide_banner -loglevel error -i $S -i work/final.social.wav -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -preset slow -crf 21 -pix_fmt yuv420p -r 60 "${aac[@]}" -movflags +faststart out/logic-pro-mcp-demo-social.mp4
  # README GIF from the social cut (silent by nature): small palette, 720 px wide, 12 fps
  ffmpeg -y -hide_banner -loglevel error -i $S -vf "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=112:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" out/logic-pro-mcp-demo.gif
  # posters: a frame from the reveal and one from the drop
  local t_reveal t_drop
  t_reveal=$(python3 -c 'import json;print(json.load(open("work/cues.json"))["scenes"]["reveal"]["from"]+1.9)')
  t_drop=$(python3 -c 'import json;print(json.load(open("work/cues.json"))["scenes"]["build"]["from"]+4.0)')
  ffmpeg -y -hide_banner -loglevel error -ss "$t_drop" -i $V -frames:v 1 -vf "scale=1920:1080:flags=lanczos" out/poster-1080.png
  ffmpeg -y -hide_banner -loglevel error -ss "$t_reveal" -i $V -frames:v 1 -vf "scale=1280:720:flags=lanczos" out/logic-pro-mcp-thumbnail.png
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1024:576:flags=lanczos work/p1024.png && cwebp -quiet -q 82 work/p1024.png -o out/session-poster.webp
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=660:371:flags=lanczos work/p660.png && cwebp -quiet -q 82 work/p660.png -o out/session-poster-660.webp
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1024:576:flags=lanczos out/session-poster.png
  for f in out/*.mp4 out/*.webm out/*.gif out/*.png out/*.webp; do
    printf '%s\t%s\t' "$f" "$(du -h "$f" | cut -f1)"; ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate:format=duration -of csv=p=0 "$f" | tr '\n' ' '; echo
  done
}

case "${1:-all}" in
  process) shift; stage_process "$@" ;;
  render) stage_render ;;
  audio) stage_audio ;;
  encode) stage_encode ;;
  all) stage_process; stage_render; stage_audio; stage_encode ;;
  *) echo "usage: build.sh process|render|audio|encode|all" >&2; exit 2 ;;
esac
