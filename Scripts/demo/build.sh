#!/usr/bin/env bash
# Re-render the launch film from the recorded Claude Code take. Everything except the live recording is scripted here.
#
#   build.sh process     raw/take.mov + raw/client.mov + logs -> JPEG frame sequences, session.json
#   build.sh render      Remotion: silent masters (Launch 4K, Social 4K, Vertical 1080x1920), each frame-scanned
#   build.sh audio       take audio + generated beds + sound design -> mastered work/final*.wav
#   build.sh encode      every deliverable, each mapped explicitly to the mastered audio
#   build.sh check       hard gate on every deliverable: audio stream, loudness, true peak, silence gaps, frame scan
#                        at 3 luma, GIF size, webm colour tags, poster = frame 0; plus the mix checks (LRA, entrances)
#   build.sh all         process, render, audio, encode, check
#
# Inputs (written by record_claude_take.sh and typist.py): raw/take.mov raw/client.mov raw/take.meta.json
# out/claude-take.mcp.jsonl out/prompts.jsonl. Outputs land in out/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p raw/footage work out
LUFS_TARGET="${LUFS_TARGET:--14}"
PORT="${FOOTAGE_PORT:-8765}"
SCAN_LUMA="${SCAN_LUMA:-3}"
LRA_RANGE="${LRA_RANGE:-0,12}"  # at most 12 LU: the entrance steps (>= +3 dB each) take priority over a narrow range
CLIENT_MODEL="${CLIENT_MODEL:-Sonnet 5.5}"
KEEP_PROMPTS="${KEEP_PROMPTS:-0}"  # end the film after N requests (0 = all); the rest are listed in session.json

stage_process() {
  ffmpeg -y -hide_banner -loglevel error -i raw/take.mov -vn -ac 2 -ar 48000 -c:a pcm_s16le raw/take.audio.wav
  rm -rf raw/footage/take raw/footage/client && mkdir -p raw/footage/take raw/footage/client
  ffmpeg -y -hide_banner -loglevel error -i raw/take.mov -vf fps=60 -q:v 3 raw/footage/take/%05d.jpg
  ffmpeg -y -hide_banner -loglevel error -i raw/client.mov -vf fps=30 -q:v 2 raw/footage/client/%05d.jpg
  python3 align_claude.py --tap out/claude-take.mcp.jsonl --prompts out/prompts.jsonl --meta raw/take.meta.json \
    --take raw/take.mov --client raw/client.mov --audio raw/take.audio.wav --client-model "$CLIENT_MODEL" --keep-prompts "$KEEP_PROMPTS" \
    --out motion/public/data/session.json "$@"
  python3 - <<'PY'
import json, os
p = "motion/public/data/session.json"
s = json.load(open(p))
s["film"]["take"]["frames"] = len([f for f in os.listdir("raw/footage/take") if f.endswith(".jpg")])
s["film"]["client"]["frames"] = len([f for f in os.listdir("raw/footage/client") if f.endswith(".jpg")])
json.dump(s, open(p, "w"), indent=1, ensure_ascii=False)
print("frames:", s["film"]["take"]["frames"], s["film"]["client"]["frames"])
PY
}

serve_footage() {
  (cd raw/footage && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  SERVER_PID=$!
  trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
  sleep 1
  export REMOTION_FOOTAGE_BASE="http://127.0.0.1:$PORT"
}

# Masters are rendered as a JPEG sequence, encoded, then frame-scanned at SCAN_LUMA. Remotion now and then captures a
# frame before the page has painted (a frame of bare background: v2 shipped one at 45.6 s, this take produced two).
# Any frame the scan flags is rendered again on its own as a still and put back, then the master is re-encoded and
# re-scanned; a dropout that survives the re-render (one that is really in the footage) still fails the build.
render_comp() { # comp scale name
  local comp=$1 s=$2 name=$3 dir="${FRAMES_ROOT:-/private/tmp/lpm-demo-frames}/$3" out="work/$3.silent.mp4" conc="${CONCURRENCY:-6}"
  # outside the worktree: Remotion rejects a sequence path with a dot in it. A finished sequence (.complete) is reused.
  if [ ! -f "$dir/.complete" ]; then
    rm -rf "$dir" && mkdir -p "$(dirname "$dir")"
    (cd motion && npx remotion render src/index.ts "$comp" "$dir" --sequence --scale="$s" --concurrency="$conc" --image-format=jpeg --jpeg-quality=95)
    touch "$dir/.complete"
  fi
  local files=("$dir"/element-*.jpeg) first pad
  first=$(basename "${files[0]}"); pad=${first#element-}; pad=${pad%.jpeg}; pad=${#pad}
  for pass in 1 2 3 4; do
    ffmpeg -y -hide_banner -loglevel error -framerate 60 -pattern_type glob -i "$dir/element-*.jpeg" \
      -vf "scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p" -c:v libx264 -preset slow -crf 14 \
      -profile:v high -g 120 -keyint_min 120 "${COLOR[@]}" -movflags +faststart "$out"
    local rep; rep=$(python3 scan_frames.py "$out" --max-dip "$SCAN_LUMA") && { echo "$rep"; return 0; }
    echo "$rep"
    [ "$pass" = 4 ] && return 1
    local bad; bad=$(echo "$rep" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(" ".join(str(i) for i in sorted(set(r["isolated_dropouts"] + r["mid_film_black_frames"]))))')
    for f in $bad; do
      echo "re-rendering $name frame $f (pass $pass)"
      (cd motion && npx remotion still src/index.ts "$comp" "$dir/element-$(printf "%0${pad}d" "$f").jpeg" --frame="$f" --scale="$s" --image-format=jpeg --jpeg-quality=95 >/dev/null)
    done
  done
}

stage_render() {
  [ -d motion/node_modules ] || (cd motion && npm ci --no-audit --no-fund)
  serve_footage
  export REMOTION_MOTION_BLUR="${MOTION_BLUR:-1}"
  local scale=2
  [ "${PREVIEW:-0}" = 1 ] && { scale=0.5; export REMOTION_MOTION_BLUR=0; }
  for comp in ${COMPS:-Launch Social Vertical}; do
    local s=$scale; [ "$comp" = Vertical ] && s=$(python3 -c "print(min(1, $scale))")
    render_comp "$comp" "$s" "$(echo $comp | tr 'A-Z' 'a-z')"
  done
}

# Mastering keeps the build the film is about: a gentle EQ, light compression (1.6:1 above -20 dBFS), then a plain gain
# to -14 LUFS and an oversampled peak limiter. No dynamic loudness normalisation (it flattened v2 to 2.5 LU).
# +2 dB around 90 Hz lifts the bass (A1-G2 roots) under the pad, which is voiced from E3 up
MASTER_EQ="highpass=f=30,equalizer=f=90:t=q:w=1:g=2,equalizer=f=3200:t=q:w=1:g=1.5,treble=g=2:f=8000"
MASTER_COMP="${MASTER_COMP:-acompressor=threshold=-20dB:ratio=1.6:attack=25:release=300:makeup=1}"
LIMIT="aresample=192000,alimiter=limit=0.76:attack=2:release=60:level=0,aresample=48000"

integrated() { ffmpeg -hide_banner -nostats -i "$1" -af ebur128 -f null - 2>&1 | sed -n '/Summary:/,$p' | awk '/I:/{print $2; exit}'; }

master() { # $1 in.wav  $2 out.wav
  ffmpeg -y -hide_banner -loglevel error -i "$1" -af "$MASTER_EQ,$MASTER_COMP" -c:a pcm_s24le work/m.pre.wav
  local i g
  i=$(integrated work/m.pre.wav)
  g=$(python3 -c "print(round($LUFS_TARGET - ($i), 2))")
  for _ in 1 2 3 4; do
    ffmpeg -y -hide_banner -loglevel error -i work/m.pre.wav -af "volume=${g}dB,$LIMIT" -c:a pcm_s24le "$2"
    i=$(integrated "$2")
    python3 -c "import sys; sys.exit(0 if abs($i - ($LUFS_TARGET)) <= 0.2 else 1)" && break
    # the limiter took some level: add the shortfall to the gain and try again
    g=$(python3 -c "print(round($g + $LUFS_TARGET - ($i), 2))")
  done
  echo "mastered $2: $(integrated "$2") LUFS"
}

entrances() { python3 -c 'import json;print(",".join("%.3f:%.3f" % (e["tau"], e["tauEnd"]) for e in json.load(open("work/cues.json"))["entrances"]))'; }

stage_audio() {
  node --experimental-strip-types motion/scripts/export-cues.mjs > work/cues.json 2>/dev/null
  python3 sound_design.py --cues work/cues.json --take raw/take.audio.wav --out work/mix.wav
  python3 sound_design.py --cues work/cues.json --take raw/take.audio.wav --out work/mix.social.wav --social
  master work/mix.wav work/final.wav
  master work/mix.social.wav work/final.social.wav
  python3 qa_audio.py work/final.wav --entrances "$(entrances)" --lra "$LRA_RANGE" | tee out/audio-qa.json || true
  python3 qa_audio.py work/final.social.wav | tee out/audio-qa.social.json || true
}

# BT.709 everywhere. x264 takes the VUI flags directly; for VP9 the tags are also set on the frames (setparams),
# because libvpx writes what the frames carry. Web files get a 2 s GOP so seeking in the player is quick.
COLOR=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -x264-params colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv)
COLOR_NOX=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)
SCALE709="scale=1920:1080:flags=lanczos:out_color_matrix=bt709,format=yuv420p"
TAG709="setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"

stage_encode() {
  local V=work/launch.silent.mp4 S=work/social.silent.mp4 VV=work/vertical.silent.mp4 A=work/final.wav SA=work/final.social.wav
  local aac=(-c:a aac -b:a 256k -ar 48000)
  local map=(-map 0:v:0 -map 1:a:0)
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -c:v copy "${COLOR_NOX[@]}" "${aac[@]}" -shortest -movflags +faststart out/logic-pro-mcp-launch-4k.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -vf "$SCALE709" -c:v libx264 -preset slow -crf 21 -profile:v high -r 60 -g 120 -keyint_min 120 "${COLOR[@]}" "${aac[@]}" -shortest -movflags +faststart out/logic-pro-mcp-demo.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -vf "$SCALE709,fps=30" -c:v libx264 -preset slow -crf 24 -maxrate 6M -bufsize 12M -profile:v high -g 60 -keyint_min 60 "${COLOR[@]}" -c:a aac -b:a 160k -ar 48000 -shortest -movflags +faststart out/logic-pro-mcp-demo-web.mp4
  ffmpeg -y -hide_banner -loglevel error -i $V -i $A "${map[@]}" -vf "$SCALE709,fps=30,$TAG709" -c:v libvpx-vp9 -b:v 0 -crf 34 -row-mt 1 -cpu-used 2 -g 60 "${COLOR_NOX[@]}" -c:a libopus -b:a 128k -shortest out/logic-pro-mcp-demo-web.webm
  ffmpeg -y -hide_banner -loglevel error -i $S -i $SA "${map[@]}" -vf "$SCALE709" -c:v libx264 -preset slow -crf 21 -r 60 -g 120 "${COLOR[@]}" "${aac[@]}" -shortest -movflags +faststart out/logic-pro-mcp-demo-social.mp4
  ffmpeg -y -hide_banner -loglevel error -i $VV -i $SA "${map[@]}" -vf "scale=1080:1920:flags=lanczos:out_color_matrix=bt709,format=yuv420p" -c:v libx264 -preset slow -crf 21 -r 60 -g 120 "${COLOR[@]}" "${aac[@]}" -shortest -movflags +faststart out/logic-pro-mcp-demo-vertical.mp4
  # README GIF: the social cut's picture, silent by nature, sized to stay under 5 MB
  ffmpeg -y -hide_banner -loglevel error -i $S -vf "fps=${GIF_FPS:-10},scale=${GIF_W:-600}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=${GIF_COLORS:-80}:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" out/logic-pro-mcp-demo.gif
  # poster and thumbnail: frame 0 of the film itself (the finished, branded headline), so pressing play changes nothing
  ffmpeg -y -hide_banner -loglevel error -i $V -frames:v 1 -vf "scale=1920:1080:flags=lanczos" out/poster-1080.png
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1280:720:flags=lanczos out/logic-pro-mcp-thumbnail.png
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1024:576:flags=lanczos work/p1024.png && cwebp -quiet -q 80 work/p1024.png -o out/session-poster.webp
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=660:371:flags=lanczos work/p660.png && cwebp -quiet -q 80 work/p660.png -o out/session-poster-660.webp
  ffmpeg -y -hide_banner -loglevel error -i out/poster-1080.png -vf scale=1024:576:flags=lanczos out/session-poster.png
}

DELIVERABLES=(out/logic-pro-mcp-launch-4k.mp4 out/logic-pro-mcp-demo.mp4 out/logic-pro-mcp-demo-web.mp4 out/logic-pro-mcp-demo-web.webm out/logic-pro-mcp-demo-social.mp4 out/logic-pro-mcp-demo-vertical.mp4)

stage_check() {
  local fail=0
  mkdir -p work/qa
  for f in "${DELIVERABLES[@]}"; do
    local n; n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | wc -l | tr -d ' ')
    if [ "$n" -lt 1 ]; then echo "FAIL $f: no audio stream"; fail=1; continue; fi
    local wav="work/qa/$(basename "$f").wav"
    ffmpeg -y -hide_banner -loglevel error -i "$f" -map 0:a:0 -ac 2 -ar 48000 -c:a pcm_s24le "$wav"
    local rep; rep=$(python3 qa_audio.py "$wav" || true)
    local lufs tp lra gaps
    lufs=$(echo "$rep" | python3 -c 'import json,sys;print(json.load(sys.stdin)["integrated_lufs"])')
    tp=$(echo "$rep" | python3 -c 'import json,sys;print(json.load(sys.stdin)["true_peak_dbtp"])')
    lra=$(echo "$rep" | python3 -c 'import json,sys;print(json.load(sys.stdin)["loudness_range_lu"])')
    gaps=$(echo "$rep" | python3 -c 'import json,sys;print(json.load(sys.stdin)["silence_gaps_start_s"])')
    echo "$f  audio=$n  LUFS=$lufs  TP=$tp  LRA=$lra  gaps=$gaps  $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,color_primaries,color_transfer,color_space:format=duration -of csv=p=0 "$f" | tr '\n' ' ')"
    python3 - "$lufs" "$tp" "$f" "$gaps" <<'PY' || fail=1
import sys
lufs, tp, f, gaps = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4]
if lufs < -30: sys.exit(f"FAIL {f}: {lufs} LUFS is below -30 (silent audio)")
if abs(lufs + 14) > 1.0: sys.exit(f"FAIL {f}: {lufs} LUFS is not near -14")
if tp > -1.0: sys.exit(f"FAIL {f}: true peak {tp} dBTP")
if gaps != "[]": sys.exit(f"FAIL {f}: silence gaps at {gaps}")
PY
  done
  for f in "${DELIVERABLES[@]}" out/logic-pro-mcp-demo.gif work/launch.silent.mp4 work/social.silent.mp4 work/vertical.silent.mp4; do
    python3 scan_frames.py "$f" --max-dip "$SCAN_LUMA" || fail=1
  done
  local gif; gif=$(stat -f %z out/logic-pro-mcp-demo.gif)
  echo "gif bytes=$gif"; [ "$gif" -lt 5000000 ] || { echo "FAIL gif is $gif bytes (limit 5 MB)"; fail=1; }
  local tags; tags=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries,color_transfer,color_space -of csv=p=0 out/logic-pro-mcp-demo-web.webm)
  echo "webm colour tags: $tags"; [ "$tags" = "bt709,bt709,bt709" ] || { echo "FAIL webm colour tags"; fail=1; }
  ffmpeg -y -hide_banner -loglevel error -i out/logic-pro-mcp-demo.mp4 -frames:v 1 work/qa/frame0.png
  local psnr; psnr=$(ffmpeg -hide_banner -i work/qa/frame0.png -i out/poster-1080.png -lavfi psnr -f null - 2>&1 | sed -n 's/.*average:\([0-9.inf]*\).*/\1/p')
  echo "poster vs frame 0 PSNR=$psnr dB"; python3 -c "import sys; v='$psnr'; sys.exit(0 if v=='inf' or float(v) >= 35 else 1)" || { echo "FAIL poster is not frame 0"; fail=1; }
  node --experimental-strip-types motion/scripts/export-cues.mjs > work/cues.json 2>/dev/null
  python3 qa_audio.py work/final.wav --entrances "$(entrances)" --lra "$LRA_RANGE" > out/audio-qa.json || fail=1
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
