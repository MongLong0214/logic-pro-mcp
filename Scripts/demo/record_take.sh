#!/usr/bin/env bash
# Record one take: capture Logic's window (+ its audio) while the scripted MCP client drives the session.
#   record_take.sh reset      put the session back to the start state before take A (not filmed)
#   record_take.sh resetB     same for take B (tempo 112)
#   record_take.sh A          take A: read state, set tempo, mix the faders (transport stopped)
#   record_take.sh B          take B: play the song, unmuting each part on cue
# Run it from the terminal that holds Screen Recording permission (here: tmux -L logic-aqua, window gate:0).
set -euo pipefail
cd "$(dirname "$0")"
T="${1:?usage: record_take.sh reset|A|B}"
export LOGIC_PRO_MCP_BINARY="${LOGIC_PRO_MCP_BINARY:-$PWD/.cache/release/LogicProMCP}"
mkdir -p raw out .cache
if [ "$T" = reset ]; then            # before take A: tempo 90, every fader down, playhead at bar 1
  python3 driver.py --scenario reset --log out/reset.jsonl
  exit 0
fi
if [ "$T" = resetB ]; then           # before take B: tempo already 112 from take A
  python3 driver.py --scenario reset --reset-tempo 112 --log out/resetB.jsonl
  exit 0
fi
CAP=.cache/LogicCapture
[ -x "$CAP" ] || swiftc -O -parse-as-library -swift-version 5 -o "$CAP" capture/LogicCapture.swift
rm -f "raw/$T.mov.stop"
"$CAP" --bundle com.apple.logic10 --out "raw/$T.mov" --fps 60 --max-seconds 170 > "raw/$T.capture.log" 2>&1 &
CAPPID=$!
for _ in $(seq 1 100); do grep -q first_frame_epoch "raw/$T.capture.log" 2>/dev/null && break; sleep 0.1; done
python3 - "$T" <<'PY'
import json, re, sys
t = sys.argv[1]
for line in open(f"raw/{t}.capture.log"):
    m = re.search(r'"first_frame_epoch":([0-9.]+)', line)
    if m:
        json.dump({"first_frame_epoch": float(m.group(1))}, open(f"raw/{t}.meta.json", "w"))
        break
else:
    sys.exit("capture did not start (Screen Recording permission? Logic window on screen?)")
PY
sleep 1.5                      # untouched Logic at the head of the take
case "$T" in
  A) python3 driver.py --scenario setup --log out/setup.jsonl; sleep 2 ;;
  B) python3 driver.py --scenario play  --log out/play.jsonl;  sleep 3.5 ;;
esac
touch "raw/$T.mov.stop"
wait "$CAPPID"
tail -n 2 "raw/$T.capture.log"
