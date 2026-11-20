# Launch film pipeline

Re-renders the Logic Pro MCP launch film (`docs/media/logic-pro-mcp-demo.*`) from a live Logic Pro session.
Only the recording needs a Mac with Logic; everything after it is scripted and deterministic.

## What the film claims, and what backs it

Every operation on screen is a live MCP call against the **published release binary** (`fetch-binary.sh`, checked
against the release's `SHA256SUMS.txt`) driving Logic Pro. The driver (`driver.py`) refuses any mutating call that is not
one of the 17 operations live-qualified on Logic Pro 13.0 (`docs/qualification/not-qualified-logic13.json` lists the
other 121; `driver.py --list-ops` prints the allowed set). Request, response and measured round-trip of every call go to
a JSONL log, and the transcript, timers and "verified" captions in the film are rendered from that log, never typed.

Not shown as MCP work (done as preparation, listed in `docs/media/README.md`): creating the tracks, importing the MIDI,
choosing instruments and plug-ins, and the channel-strip processing. Those are either not qualified on 13.0 or not
exposed by the server yet.

## Layout

| path | role |
|---|---|
| `music/compose.py` | deterministic arrangement ("Signal", 112 BPM, A minor, 36 bars): writes `music/out/*.mid` + `arrangement.json` |
| `capture/LogicCapture.swift` | ScreenCaptureKit recorder: Logic's window at native Retina pixels, 60 fps, plus Logic's own audio |
| `driver.py` | scripted MCP client (stdio JSON-RPC), scenarios `reset`, `setup` (take A), `play` (take B) |
| `record_take.sh` | runs capture + driver together; run it in the terminal that holds Screen Recording permission |
| `align.py` | driver logs + capture metadata -> `motion/public/data/session.json` |
| `motion/` | Remotion project: scenes, kinetic captions, transcript, camera moves (brand tokens from the landing site) |
| `sound_design.py` | generated UI/whoosh sound design (numpy), mixed under the song |
| `qa_audio.py` | LUFS, true peak, clipping, silence gaps, click detection |
| `build.sh` | `process`, `render`, `audio`, `encode`, `all` |

## Re-render

```bash
Scripts/demo/fetch-binary.sh v3.19.0          # the exact published binary
python3 Scripts/demo/music/compose.py         # regenerate the MIDI (identical every run)
# live: prepare the fixture project (docs/media/README.md), then in the permitted terminal:
Scripts/demo/record_take.sh reset && Scripts/demo/record_take.sh A && Scripts/demo/record_take.sh B
Scripts/demo/build.sh all                     # PREVIEW=1 for a fast 540p draft
```

Outputs land in `Scripts/demo/out/` (the 4K master stays local; the repo carries the 1080p mp4, gif and posters).

## Timing honesty

No clip is retimed. Video footage plays at 1.0x everywhere; the speed section replays the real mixer batch on its real
clock. The only retime-free "acceleration" is none. If a future edit speeds a clip up, the on-screen label must say so.
