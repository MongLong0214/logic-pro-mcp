# Troubleshooting Guide

Diagnostic recipes for common issues, listed by symptom. Each entry gives the likely cause and a concrete fix.

For MCU-specific problems, see [MCU-SETUP.md](MCU-SETUP.md).

---

## Server Won't Start

### `claude mcp add` succeeds but server never responds

**Cause:** binary not on `PATH`, or permissions missing.

```bash
which LogicProMCP                                 # expect: /usr/local/bin/LogicProMCP
LogicProMCP --check-permissions                   # expect both granted
ls -l /usr/local/bin/LogicProMCP                  # expect executable bit set
```

If `--check-permissions` reports `NOT VERIFIABLE (Logic Pro not running)`, start Logic Pro once and retry.

### Server starts but `tools/list` returns empty / times out

**Cause:** stdio framing mismatch or server crashed during init.

Check stderr:
```bash
LogicProMCP 2>/tmp/mcp-stderr.txt < /dev/null &
sleep 2
kill %1
head -40 /tmp/mcp-stderr.txt
```

Look for lines like:
- `MIDIPortManager started` — CoreMIDI initialized
- `Accessibility channel started` — AX ready
- `Starting logic-pro-mcp v2.0.0 — 8 tools, 6 resources, 7 channels` — composition complete

If you see `AccessibilityError.notTrusted`, grant Accessibility permission.

---

## Permissions

### Accessibility denied

```
Accessibility: NOT GRANTED
  → System Settings > Privacy & Security > Accessibility → add your terminal app
```

**Fix:**
1. Open **System Settings → Privacy & Security → Accessibility**
2. Click **+** and add the parent process (e.g. `Terminal.app`, `Claude Code.app`, or your IDE).
3. Toggle the switch ON.
4. **Restart the MCP server** (Claude Code → toggle MCP off/on, or kill + restart terminal).

macOS caches trust per-bundle. Changes take effect only for processes started *after* the toggle.

### Automation denied

```
Automation (Logic Pro): NOT GRANTED
  → System Settings > Privacy & Security > Automation → allow control of Logic Pro
```

**Fix:**
1. With Logic Pro running, trigger any AppleScript operation (e.g. `logic_project is_running`).
2. macOS pops up a consent dialog: *"Terminal wants access to control Logic Pro"* — click **OK**.
3. If you clicked Deny previously: **System Settings → Privacy & Security → Automation → [your terminal] → Logic Pro** → toggle ON.
4. Restart the MCP server.

### Automation: `NOT VERIFIABLE`

**Cause:** Logic Pro is not running.

**Fix:** Launch Logic Pro once, then `LogicProMCP --check-permissions` again. Automation verification requires Logic Pro to be alive so the consent dialog can fire.

---

## MCU / Mixer

### `mixer.set_volume` returns "All channels exhausted … MCU feedback not detected"

**Cause:** MCU control surface not registered in Logic Pro, or handshake failed.

**Fix:** See [MCU-SETUP.md](MCU-SETUP.md) — register `LogicProMCP-MCU-Internal` in **Control Surfaces → Setup**.

Mixer operations have **no fallback** — MCU registration is mandatory.

### MCU was registered but `health.mcu.feedback_stale: true`

**Cause:** Logic Pro isn't actively sending MCU feedback.

**Fix:**
1. Restart Logic Pro.
2. Re-open the Control Surface Setup window once (no changes needed — just open and close).
3. Click in the Logic Pro mixer area; movement should trigger feedback.
4. Check `health` again after 2 seconds.

### Mixer shows wrong track count

**Cause:** MCU banks in groups of 8. The visible "strip range" depends on `bank` position.

**Fix:** Use `logic_navigate goto_bar` or Logic Pro's bank buttons to move to the intended 8-track window. MCU inherently only surfaces 8 strips at a time to the external device.

---

## MIDI

### Virtual MIDI ports not visible in Logic Pro

**Cause:** MCP server not running when Logic Pro's dropdown was opened.

**Fix:** Start the MCP server **before** opening Logic Pro's MIDI port dropdown. If already open, close and reopen the dropdown — Logic refreshes the port list on open.

### `midi.send_note` succeeds but no sound in Logic Pro

**Cause:** No track in Logic Pro has its MIDI input set to `LogicProMCP-Out` (or the MCP server's CoreMIDI source).

**Fix:**
1. In Logic Pro, select an instrument track.
2. Set **Record Enable** (R button).
3. In track inspector, set **Input** to `LogicProMCP-Out` (or `All` to accept from any source).

Or use Scripter for deterministic plugin parameter control (no track routing needed).

### SysEx transmission fails

**Cause:** Bytes don't start with `F0` or don't end with `F7`.

**Fix:** MCU server validates F0/F7 framing. Pass bytes as either:
- `{"bytes": "F0 7F 7F 06 02 F7"}` (hex string, space-separated)
- `{"bytes": [240, 127, 127, 6, 2, 247]}` (integer array)

---

## MIDIKeyCommands / Scripter

### `manual_validation_required` status

**Cause:** MIDIKeyCommands and Scripter channels write MIDI to Logic Pro, but the server can't programmatically verify that Logic Pro's Key Commands assignments or Scripter MIDI FX are active. You must approve them explicitly.

**Fix:**
1. Complete the manual setup (Key Commands MIDI Learn, or Scripter script load).
2. Approve the channel:

```bash
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
LogicProMCP --list-approvals
```

3. Restart the MCP server so the router picks up the new approvals.

### Key Commands don't trigger in Logic Pro

**Cause:** Logic Pro's Key Commands window doesn't have the CC→shortcut mappings.

**Fix:**
1. Open **Logic Pro → Key Commands → Edit** (`⌥K`).
2. Click the **"Learn by Key Label"** button.
3. Select a command (e.g. "Undo").
4. Press the corresponding CC button (refer to `Scripts/keycmd-preset.plist` for the CC→command mapping).

Alternatively, import the preset file:
```bash
Scripts/install-keycmds.sh
```

---

## AppleScript / Project Lifecycle

### `project.open` returns "Failed to verify opened project"

**Cause:** Logic Pro opened the file but is stuck on a save/migrate/chooser dialog.

**Fix:**
1. Bring Logic Pro to the front and dismiss any dialogs.
2. Retry `project.open`. The server auto-retries once after closing any front document.

### `project.open` rejects a valid path

**Cause:** Path validation (`AppleScriptSafety.isValidProjectPath`) enforces:
- Absolute path (starts with `/`)
- `.logicx` extension (case-sensitive on some filesystems)
- No control characters
- Not under `/dev/`
- Directory exists with `Resources/ProjectInformation.plist` and `Alternatives/*/ProjectData`

**Fix:** Verify the path is a genuine Logic Pro project package:

```bash
ls "/path/to/project.logicx/Resources/ProjectInformation.plist"  # must exist
ls "/path/to/project.logicx/Alternatives"/*/ProjectData           # must exist
```

### `project.save_as` fails silently

**Cause:** Logic Pro's Save As dialog didn't appear (window focus issue).

**Fix:**
1. Bring Logic Pro to front: `osascript -e 'tell application "Logic Pro" to activate'`
2. Retry.

---

## State & Caching

### `transport.get_state` returns empty or stale data

**Cause:** No project is open, or MCU hasn't completed handshake.

**Check:**
```
logic_system health → mcu.connected, cache.transport_age_sec
```

- `cache.transport_age_sec > 10` and MCU disconnected → AX poll is the only source.
- `cache.transport_age_sec > 60` → poller may have stopped. Run `logic_system refresh_cache`.

### Track list doesn't update after creating a new track

**Cause:** AX polling runs every 5s. The cache may not have refreshed yet.

**Fix:**
```
logic_system refresh_cache
```

Or wait up to 5 seconds.

---

## Performance

### Tool calls take >3 seconds

**Likely cause:** AX-based reads (tracks, mixer) on a large project (100+ tracks).

**Mitigations:**
- Use `logic_system health` to confirm MCU is connected — MCU reads are <10ms vs 500ms+ for AX.
- Keep only the tracks you need visible in the Logic Pro arrange view — AX scans visible elements.
- Check `health.cache.poll_mode`: `"active"` means recent tool access, polling adaptive; `"idle"` uses longer intervals.

### Memory grows over time

**Expected:** 40–70 MB baseline, <100 MB after heavy use.

If memory exceeds 200 MB:
1. Capture `health` output.
2. Restart the MCP server.
3. File a bug with `health` JSON + stderr log.

---

## Logging

### Enable DEBUG log

```bash
# For Claude Code integration, set the env var in Claude's config.
# For manual testing:
LOG_LEVEL=DEBUG LogicProMCP 2>/tmp/mcp-debug.log
```

Subsystems:
- `server`, `router`, `main` — lifecycle
- `mcu`, `midi`, `keycmd`, `scripter` — MIDI path
- `ax`, `poller` — Accessibility
- `cgEvent`, `appleScript` — fallback channels

### Finding errors in logs

```bash
grep -iE "error|warn|fail" /tmp/mcp-debug.log
```

### Capture a full debug session

```bash
LOG_LEVEL=DEBUG python3 scripts/live-e2e-test.py 2>/tmp/mcp-session.log
```

---

## Emergency Recovery

### Unresponsive server

```bash
# Force-kill
pkill -9 LogicProMCP

# Restart via Claude Code (toggle MCP connection off/on)
# Or run manually
LogicProMCP --check-permissions
```

### Corrupted approval store

```bash
rm ~/Library/Application\ Support/LogicProMCP/operator-approvals.json
LogicProMCP --list-approvals   # should report empty
# Re-approve as needed
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
```

### Virtual MIDI ports stuck after crash

```bash
# List MIDI clients
system_profiler SPMidiDataType | grep -A 2 LogicProMCP

# Restart CoreMIDI server (nuclear option)
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

Virtual MIDI ports registered by crashed processes usually disappear within 30 seconds; if they persist, restarting the system audio daemon clears them.

---

## Getting Help

1. Run `LogicProMCP --check-permissions` — paste output.
2. Capture `logic_system health` JSON.
3. Capture last 100 lines of `LOG_LEVEL=DEBUG` stderr.
4. File an issue with:
   - macOS version (`sw_vers`)
   - Logic Pro version
   - Server version (`LogicProMCP --version` if available, or the release tag)
   - The three captures above
