#!/usr/bin/env bash
# Record the film's single take: capture Logic's window (+ its audio) while the scripted MCP client drives the session.
#   record_take.sh reset     put the session back to the start state (not filmed): tempo 90, faders down, count-in off
#   record_take.sh film      the take: read, tempo, placement, play, five entrances, mixing rides, readback, stop
# Run it from the terminal that holds Screen Recording permission (here: tmux -L logic-aqua, window gate:0).
set -euo pipefail
cd "$(dirname "$0")"
T="${1:?usage: record_take.sh reset|film}"
export LOGIC_PRO_MCP_BINARY="${LOGIC_PRO_MCP_BINARY:-$PWD/.cache/release/LogicProMCP}"
mkdir -p raw out .cache
if [ "$T" = reset ]; then
  python3 driver.py --scenario reset --log out/reset.jsonl
  exit 0
fi
CAP=.cache/LogicCapture
[ -x "$CAP" ] || swiftc -O -parse-as-library -swift-version 5 -o "$CAP" capture/LogicCapture.swift
rm -f "raw/film.mov.stop"
"$CAP" --bundle com.apple.logic10 --out "raw/film.mov" --fps 60 --max-seconds 170 > "raw/film.capture.log" 2>&1 &
CAPPID=$!
for _ in $(seq 1 100); do grep -q first_frame_epoch "raw/film.capture.log" 2>/dev/null && break; sleep 0.1; done
python3 - <<'PY'
import json, re, sys
for line in open("raw/film.capture.log"):
    m = re.search(r'"first_frame_epoch":([0-9.]+)', line)
    if m:
        json.dump({"first_frame_epoch": float(m.group(1))}, open("raw/film.meta.json", "w"))
        break
else:
    sys.exit("capture did not start (Screen Recording permission? Logic window on screen?)")
PY
sleep 1.0
python3 driver.py --scenario film --log out/film.jsonl
sleep 3.5                      # the last chord rings out
touch "raw/film.mov.stop"
wait "$CAPPID"
tail -n 2 "raw/film.capture.log"
