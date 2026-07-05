# Troubleshooting

Start with:

```bash
LogicProMCP doctor
LogicProMCP --check-permissions
```

## Install

### Homebrew refuses the tap

Homebrew 6.0+ requires trusting third-party taps:

```bash
brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
brew trust monglong0214/logic-pro-mcp
brew install logic-pro-mcp
```

### `SETUP.md` missing during `brew install`

Older Formula/tarball path mismatches caused this on v3.4.6/v3.5.0. Update the tap:

```bash
brew update
brew reinstall logic-pro-mcp
```

## Server Startup

### MCP client registers but does not respond

Run:

```bash
which LogicProMCP
LogicProMCP doctor --json
```

If the MCP client launches from a different environment, register with an absolute binary path.

### `tools/list` is empty or times out

Check the MCP client logs, confirm the command path, and run `LogicProMCP --check-permissions`. macOS TCC permissions apply to the parent app that launches the server.

### Concurrent large reads appear to time out ("no response")

The server speaks newline-delimited JSON-RPC over a single stdout pipe, and it serializes writes (one response frame is fully flushed before the next starts — frames never interleave or corrupt). If a client fires several large reads at once — e.g. `logic://library/inventory`, `logic_tracks.scan_library` in disk mode, `logic://project/audit` — and does not drain stdout while it keeps sending, the pipe back-pressures: later responses queue behind the one being flushed and can exceed a short client deadline, looking like "no response." Run alone, each returns quickly.

This is client-side backpressure, not a server stall. Mitigations:

- Drain stdout concurrently with sending (read responses on a separate thread/task), as any correct MCP stdio client does.
- Or serialize very large reads (await each before issuing the next).
- Prefer resource reads for polling large state instead of firing many in parallel.

The server produces every response, complete and well-formed, under concurrent load (covered by `Issue220ConcurrentLargeReadTests` and the live-e2e pipelined-read check).

## Permissions

### Accessibility denied

Enable Accessibility for the launcher app in **System Settings -> Privacy & Security -> Accessibility**.

### Automation denied or not verifiable

Launch Logic Pro once, then grant Automation access for the launcher app under **Privacy & Security -> Automation -> Logic Pro**.

`--check-permissions`, `logic_system health`, and `doctor` report Automation as one of three states — read them differently:

- **`not_granted`**: the probe ran and macOS denied it. Grant Automation as above.
- **`not_verifiable`**: the probe itself could not complete (it timed out or failed to spawn). This is an infrastructure failure, **not** a denial — do not assume the permission is missing. Re-run the check on a responsive session; if it persists, investigate what is blocking the probe (a wedged Logic UI, a stuck modal, or a sandbox that prevents spawning `osascript`) rather than re-granting an already-correct permission.
- **`granted`**: verified working.

(Before v3.8.0 a `not_verifiable` outcome was mis-reported as a false "Automation NOT GRANTED".)

## Logic Pro State

### Health says Logic is not ready

Open Logic Pro and create or open a project. Doctor does not launch or focus Logic for you.

### `logic://tracks` shows placeholders

Make the main Tracks area visible and wait for one refresh. Placeholder rows are treated as untrusted and should not be used for writes.

### `logic://markers` is empty

On Logic 12.2, marker reads require the marker list surface to be available. An empty list can be the honest result when the UI surface is closed or not exposed.

### `logic://project/info.trackCount` is `0` or lower than visible tracks

Refresh `logic://tracks` first. Current builds promote trusted live track-cache counts into project info when saved metadata is incomplete.

## MCU and Mixer

### Mixer writes return `channels_exhausted`

Register the Mackie Control surface and set both ports to `LogicProMCP-MCU-Internal`; see [SETUP.md](SETUP.md).

### Mixer writes return `echo_timeout_500ms`

Logic accepted the host write path but did not echo enough feedback for MCU verification. Confirm MCU registration, make the mixer visible, and read `logic://mcu/state`.

### Mixer values do not update

Read `logic://mixer` after the write. `set_volume` and `set_pan` use visible-strip AX readback; `set_master_volume` depends on MCU feedback. `set_send` is not exposed (State C `command_not_exposed`), so there is no send write to verify.

## MIDI

### Virtual MIDI ports are not visible

Start the MCP server once, then check:

```bash
LogicProMCP doctor
```

If CoreMIDI is stale after a crash, restart Logic Pro first. Restart CoreMIDI only as a last resort.

### `send_note` succeeds but no sound plays

Select an instrument track, verify the channel is `1..16`, and confirm the track has a playable instrument.

### `import_file` rejects a path

MIDI imports are constrained to safe locations. Prefer `record_sequence`, which uses private server-managed temp files.

## MIDI Key Commands and Scripter

### `manual_validation_required`

The server will not claim Key Commands or Scripter are ready until you approve them after manual Logic-side setup:

```bash
LogicProMCP --approve-channel MIDIKeyCommands --approval-note "Manual MIDI Learn completed"
LogicProMCP --approve-channel Scripter --approval-note "Scripter inserted on intended tracks"
```

### Key Commands do not trigger

Logic 12.2+ does not reliably import the legacy `.plist`. Use manual MIDI Learn only for the remaining keycmd-only paths listed in [SETUP.md](SETUP.md).

## Verified Plugin Apply-Back

### `get_inventory` returns State B

Open the mixer and the target plugin/track surface, then retry. Do not proceed with writes when inventory is unavailable.

### `insert_verified` fails with slot errors

Read `get_inventory`, choose an explicit empty physical slot, and pass the required confirmation metadata. Occupied slots fail closed.

### `set_param_verified` fails

Only Compressor `threshold` is currently verified writable. Unsupported parameters return `unsupported_param_readback`; arbitrary Scripter writes are legacy unverified State B.

## Project Lifecycle

### `project.open` cannot verify the project

Use an absolute `.logicx` path and confirm the project opens in Logic. Path validation rejects ambiguous or unsafe inputs before touching Logic.

### `save_as` returns `readback_mismatch`

The requested `.logicx` package was not observed, or an existing package did not show a new enough modification time. Check filesystem permissions and destination path.

## Logs

Enable debug logs for a manual run:

```bash
LOG_LEVEL=debug LogicProMCP
```

For MCP clients, set the environment variable in that client's server config.

## Recovery

```bash
pkill -f LogicProMCP
LogicProMCP doctor
```

If permissions look wrong after reinstalling, remove stale TCC entries in System Settings and grant them again to the actual launcher app.

## Still stuck?

Join the official Logic Pro MCP Discord for real-time setup help and triage: [https://discord.gg/4M3s79DBzz](https://discord.gg/4M3s79DBzz).

For a reproducible bug, open a [GitHub Issue](https://github.com/MongLong0214/logic-pro-mcp/issues) with `LogicProMCP doctor` output and `LOG_LEVEL=debug` logs — that stays searchable and is the canonical tracker.
