# Launch film pipeline

Re-renders the Logic Pro MCP launch film (`docs/media/logic-pro-mcp-demo.*`) from a live session in which a real
Claude Code client drives Logic Pro. Only the recording needs a Mac with Logic; everything after it is scripted and
deterministic.

## What the film claims, and what backs it

The take is a real Claude Code session. Its only MCP server is the **published release binary** (`fetch-binary.sh`,
checked against the release's `SHA256SUMS.txt`), registered with `--strict-mcp-config`, and Claude Code runs without
the owner's user settings, hooks or plugins (`--setting-sources project`). Plain-language requests are typed into it at
a human pace by `typist.py`; Claude chooses every tool call and its arguments itself. `mcp_tap.py` sits on the server's
stdio and records every JSON-RPC line, unchanged, with the wall-clock time it passed. The captions, before → after
values and timings in the film are rendered from that log, never typed. Claude Code's own session transcript is kept
next to it.

Both windows are recorded with ScreenCaptureKit (the two captures start one after the other, then run together): Logic's window with Logic's own audio, and the
client's Terminal window. Footage plays at 1.0x and nothing inside the session is cut. The social, vertical and GIF cuts are excerpts (headline, one unbroken stretch from the playback request through the Lead's entrance, end card) and say so in their footer.

Not shown as MCP work (done as preparation, listed in `docs/media/README.md`): creating the tracks, importing the MIDI,
choosing instruments, naming tracks and regions, hiding the track headers' Record Enable and Input Monitoring
buttons (display only; no track is armed), and the start state set by `driver.py --scenario reset`.

## Layout

| path | role |
|---|---|
| `music/compose.py` | deterministic arrangement ("Signal", 120 BPM, A minor, 48 bars): every part written from bar 1, so a fader write is heard whenever Claude makes it |
| `capture/LogicCapture.swift` | ScreenCaptureKit recorder: one app window at native pixels, 60 fps, plus that app's audio (`--title`, `--no-audio` for the client window) |
| `capture/TerminalProfile.swift` | writes the on-camera Terminal profile (opaque, large font, brand colours) |
| `record_claude_take.sh` | `prepare`, `launch` (Claude Code in tmux session `lpmdemo` + the Terminal window), `start`/`stop` (both captures), `teardown` |
| `typist.py` | types the requests into the Claude Code pane and waits for each turn to finish (`--file requests.txt`: the musician-phrased list) |
| `requests.txt` | the re-record's requests, phrased as a musician would (no values: Claude chooses them) |
| `mcp_tap.py` | pass-through stdio logger between Claude Code and the server |
| `driver.py` | scripted client used only for `--scenario reset` (off camera: tempo 90, faders down, pans centred, metronome and count-in off) |
| `align_claude.py` | tap log + prompts + capture metadata -> `motion/public/data/session.json` (before → after, no-op flags, latency stats, bar-1 time) |
| `motion/` | Remotion project: split client/Logic layout, close-ups per write, captions, cards (brand tokens from the landing site) |
| `sound_design.py` | the take's audio plus generated beds where Logic is silent (opening, after stop) and sound design |
| `scan_frames.py` | per-frame luma scan at 3 luma: fails on any isolated dropout; run on every master and deliverable |
| `qa_audio.py` | LUFS, true peak, clipping, silence gaps from the first sample, LRA (at most 24 LU: a bed 6 LU under the first part plus four steps of 3 LU is 18 before any gain ride), entrance steps (K-weighted LU, every one >= 3, the first >= 6 against the opening bed, measured from when the server confirmed the fader, against the plateau as it played, no duck), clicks |
| `build.sh` | `process`, `data`, `render`, `audio`, `encode`, `check`, `all`; `check` is the hard gate |

## Re-record and re-render

```bash
Scripts/demo/fetch-binary.sh v3.19.0           # the exact published binary
python3 Scripts/demo/music/compose.py          # regenerate the MIDI (identical every run)
# live, in the terminal that holds Screen Recording and Accessibility (tmux -L logic-aqua):
#   prepare the project (docs/media/README.md), then
Scripts/demo/driver.py --scenario reset --log Scripts/demo/out/reset.jsonl
Scripts/demo/record_claude_take.sh prepare && Scripts/demo/record_claude_take.sh launch
Scripts/demo/record_claude_take.sh start
Scripts/demo/typist.py --target lpmdemo --log Scripts/demo/out/prompts.jsonl --file Scripts/demo/requests.txt
Scripts/demo/record_claude_take.sh stop && Scripts/demo/record_claude_take.sh teardown
KEEP_PROMPTS=10 Scripts/demo/build.sh all      # the 2026-11-21 take; PREVIEW=1 for a fast 480p draft
```

Outputs land in `Scripts/demo/out/` (the 4K master stays local; the repo carries the 1080p mp4, the GIF and the
thumbnail).

## Timing honesty

No clip is retimed and nothing inside the session is cut: the film shows the take at 1.0x from just before the first
request to just after the last request it keeps (`KEEP_PROMPTS`; the 2026-11-21 take keeps ten of eleven, because the
eleventh, "Stop playback.", returned State C and is not a change that was read back). Requests left out are listed in
`session.json` under `film.omitted` and in `docs/media/README.md`. The proof card (counts of what has already happened) is laid over the live take after Claude's last answer has been on screen for 3.4 s; the end card
comes after it and holds complete for more than 6 s. Result cards appear when the server's reply came back, not when the call was sent. If a future edit speeds a clip up or cuts model think time, the on-screen label must say so.
