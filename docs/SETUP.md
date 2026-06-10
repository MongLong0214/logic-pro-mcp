# Setup Guide

Complete installation, Logic Pro integration, and verification. Should take ~10 minutes on a fresh machine.

## Requirements

- macOS 14+ (Sonoma, Sequoia)
- Logic Pro 12.0.1+
- GitHub Actions/Homebrew release assets are universal (`arm64` + `x86_64`); historical local ADHOC prerelease cuts may still be arm64-only, so audit a specific tag via `RELEASE-METADATA.json` when needed
- Claude Code or Claude Desktop

2026-06-09 release note: `v3.4.6` is the current stable GitHub Release. It publishes ADHOC-signed universal artifacts when Developer ID credentials are absent, plus `SHA256SUMS.txt` and `RELEASE-METADATA.json` for pinned installer verification.

---

## 1. Install the Binary

### Option A — Homebrew (recommended)

```bash
brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
brew install logic-pro-mcp
```

Homebrew pins both the release tarball URL and its SHA256 in the formula, and Homebrew itself is a trusted delivery channel with its own signature chain. Use this path whenever possible.

### Option B — Download-inspect-run one-line installer

The installer is **fail-closed by default**: it refuses to run without explicit SHA256 + Team ID pins. Inspect the script first, verify the hash from the release's `SHA256SUMS.txt`, then execute:

```bash
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.4.6/Scripts/install.sh -o install.sh
# inspect install.sh, then:
LOGIC_PRO_MCP_SHA256=<hex from release SHA256SUMS.txt> \
LOGIC_PRO_MCP_TEAM_ID=<team_id from RELEASE-METADATA.json> \
bash install.sh
```

If you knowingly accept same-origin provenance (hash + Team ID fetched from the same release as the binary), opt in:

```bash
LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.4.6/Scripts/install.sh)
```

See [SECURITY.md §Installer trust model](../SECURITY.md#installer-trust-model) for the threat model.

### Option C — Build from source

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
codesign --force --sign - .build/release/LogicProMCP
sudo cp .build/release/LogicProMCP /usr/local/bin/
claude mcp add --scope user logic-pro -- LogicProMCP
```

---

## 2. Grant macOS Permissions

Open **System Settings → Privacy & Security**:

1. **Accessibility** → add `LogicProMCP` (click `+` → `/usr/local/bin/LogicProMCP`) → toggle ON
2. **Automation** → find `LogicProMCP` → check the `Logic Pro` checkbox

Verify:

```bash
LogicProMCP --check-permissions
# Expected: Accessibility: granted / Automation (Logic Pro): granted
```

---

## 3. Register MCU Control Surface (mandatory for mixer control)

The MCP server controls Logic Pro's mixer via the Mackie Control Universal (MCU) protocol over a virtual MIDI port.

> ⚠️ **MCU registration is the single most failure-prone setup step** — if you skip it, mixer writes fail before sending with structured State C `{ "success": false, "error": "channels_exhausted", "operation": "mixer.set_volume", … }`. If MCU is connected but Logic does not echo a host write, the wire shape is State B `{ "success": true, "verified": false, "reason": "echo_timeout_500ms", "mcu_connected": true, … }`; v3.4.6 can still verify `set_volume` via AX readback when the mixer is readable.

1. Launch **Logic Pro**. The MCP server auto-starts when Claude Code connects.
2. Menu: **Logic Pro → Control Surfaces → Setup…** (KR: `컨트롤 서피스 → 설정…`)
3. Top-left menu: **New → Install…** (KR: `신규 → 설치…`)
4. Find **Mackie Designs → Mackie Control** → click **Add**
5. Click the newly added **Mackie Control** device card
6. In the Inspector panel, set **BOTH** In and Out ports to `LogicProMCP-MCU-Internal`
7. Close the setup window (saves automatically)

Verify in Claude:

> "Check Logic Pro MCP health and report MCU status."

Expected:

```json
{ "connected": true, "registered_as_device": true, "feedback_stale": false }
```

---

## 4. MIDIKeyCommands (optional — only if you need channel-only ops)

> ⚠️ **Logic Pro 12.2+ does NOT accept the legacy `.plist` Key Commands import.** Earlier versions of this guide instructed `Logic Pro → Key Commands → Import…` and selecting `keycmd-preset.plist`. On Logic 12.2 the Import menu is grayed out and the import will not happen — that path was never reliable on 12.2 and is removed in v3.1.6. The `.plist` file is retained **only as a CC→Command mapping reference** for the manual MIDI Learn workflow below.

### Do you actually need this?

In v3.1.6 most preset operations are routed via the regular tools — you do **not** need to bind anything manually. The handful of operations that *only* reach Logic via MIDI Key Commands are listed in the **Audited coverage matrix** below; if you don't use those ops, **skip this section entirely**.

| Time budget | Scope |
|-------------|-------|
| ~2 minutes  | Single channel-only op (e.g. `transport.capture_recording`) |
| ~5 minutes  | All channel-only / effectively-keycmd-only ops |
| ~25 minutes | Full coverage of all 48 mappingTable rows (overkill for almost everyone) |

### 4.1 Audited coverage matrix

> ⚠️ **v3.1.7 honest correction.** v3.1.6's matrix understated keycmd dependence. A v3.1.7 audit reading every channel's actual handler list against `ChannelRouter.routingTable` and `CGEventChannel.keyMap` found 7 user-facing ops where the routing chain advertises a `cgEvent` fallback **but the fallback has no `keyMap` entry** — meaning the keycmd channel is the only path that actually fires the action on Logic 12.2. The matrix below reflects the audited reality. The set is now enforced as a unit-test invariant (`RoutingAuditInvariantTests`), so future drift fails the build.

Read this column-by-column. **"requires keycmd binding?"** is the question that decides whether you need MIDI Learn for the op.

| `mappingTable` op (CC#)                                                          | MCP tool                                       | Working non-keycmd channel                  | Requires keycmd binding? |
|----------------------------------------------------------------------------------|------------------------------------------------|---------------------------------------------|--------------------------|
| `edit.undo (30)`                                                                 | `logic_edit.undo`                              | CGEvent `Cmd+Z`                             | NO                       |
| `edit.redo (31)`                                                                 | `logic_edit.redo`                              | CGEvent `Cmd+Shift+Z`                       | NO                       |
| `edit.cut/copy/paste/select_all (32-35)`                                         | `logic_edit.{cut,copy,paste,select_all}`       | CGEvent `Cmd+{X,C,V,A}`                     | NO                       |
| `edit.quantize/join/split/delete/bounce_in_place (40,43,95,94,37)`               | `logic_edit`                                   | CGEvent (mapped)                            | NO                       |
| **`edit.duplicate (97)`**                                                        | `logic_edit.duplicate`                         | _none — cgEvent fallback unmapped_          | **YES**                  |
| **`edit.normalize (96)`**                                                        | `logic_edit.normalize`                         | _none — cgEvent fallback unmapped_          | **YES**                  |
| **`edit.toggle_step_input (44)`**                                                | `logic_edit.toggle_step_input`                 | _none — cgEvent fallback unmapped_          | **YES**                  |
| `project.save (60)`                                                              | `logic_project.save`                           | AppleScript / CGEvent `Cmd+S`               | NO                       |
| `project.save_as (61)`                                                           | `logic_project.save_as`                        | AppleScript / Accessibility                 | NO                       |
| **`project.bounce (62)`**                                                        | `logic_project.bounce`                         | _none — cgEvent fallback unmapped_          | **YES**                  |
| `transport.toggle_cycle (72)`                                                    | `logic_transport.toggle_cycle`                 | Accessibility / KeyCmd / CGEvent `C` / MCU  | NO                       |
| **`transport.capture_recording (73)`**                                           | `logic_transport.capture_recording` _(none today; orphan)_ | _none — cgEvent fallback unmapped_ | **YES**                  |
| `transport.toggle_metronome (98)`                                                | `logic_transport.toggle_metronome`             | Accessibility / CGEvent `K`                 | NO                       |
| `transport.toggle_count_in (99)`                                                 | `logic_transport.toggle_count_in`              | Accessibility                               | NO                       |
| `track.create_audio/instrument/drummer/external_midi/delete (20,21,26,22,24)`    | `logic_tracks.create_*` / `.delete`            | Accessibility (primary)                     | NO                       |
| `track.duplicate (23)`                                                           | `logic_tracks.duplicate`                       | CGEvent `Cmd+D`                             | NO                       |
| `view.toggle_mixer/piano_roll/library/inspector/score_editor/step_editor (50,51,55,56,59,48)` | `logic_navigate.toggle_view`        | CGEvent (all 6 mapped)                      | NO                       |
| `nav.create_marker (39)`                                                         | `logic_navigate.create_marker`                 | CGEvent (mapped)                            | NO                       |
| `nav.zoom_to_fit (46)`                                                           | `logic_navigate.zoom_to_fit`                   | CGEvent `Z`                                 | NO                       |
| **`nav.goto_marker (38)`**                                                       | `logic_navigate.goto_marker {index}`           | _none — cgEvent fallback unmapped_          | **YES**                  |
| **`nav.delete_marker (45)`**                                                     | `logic_navigate.delete_marker {index}`         | _none — cgEvent fallback unmapped_          | **YES**                  |
| **`nav.set_zoom_level (47)`**                                                    | `logic_navigate.set_zoom_level`                | _none — cgEvent fallback unmapped_          | **YES**                  |
| `automation.toggle_view (85)`                                                    | `logic_navigate.toggle_view {automation}`      | CGEvent `A`                                 | NO                       |

**Bolded rows are the 8 effectively-keycmd-only paths.** Skip the rest of this section if you don't need any of them.

#### Orphan ops (in mappingTable + routingTable but no MCP tool currently routes to them)

These can be MIDI-Learned but no `logic_*` tool dispatches to them today. Tracked as NG6 follow-up. Binding them is purely speculative until a tool path is added.

- `automation.set_mode (84)` — MCU does NOT actually handle this operation key (it handles `track.set_automation` instead), so the keycmd channel is the only mappingTable hit.
- `note.up_semitone (90)` / `note.down_semitone (91)` / `note.up_octave (92)` / `note.down_octave (93)`
- `view.toggle_smart_controls (54)` / `view.toggle_plugin_windows (58)` / `view.toggle_automation (CC 57 — distinct from CC 85 `automation.toggle_view`)`
- `track.create_stack (25)`

### 4.2 Manual MIDI Learn — Example 1: `Edit > Undo` (CC 30, Ch 16)

> Total time: ~2 minutes per binding.

1. **Open Logic Pro and approve the keycmd port:**
   ```bash
   LogicProMCP --approve-channel MIDIKeyCommands --approval-note "Manual MIDI Learn — v3.1.6"
   ```
   This unblocks the `port:"keycmd"` routing in MCP. (You can revoke later with `--revoke-channel`.)

2. **Open Logic Pro's Key Commands editor:** `Logic Pro → Key Commands → Edit…` (⌥K). The window has a search field at the top right and a list of every command on the left.

3. **Find the command:** Type `Undo` into the search field. Click the row labelled exactly `Undo` (NOT `Undo Region/Event Position` etc.).

4. **Enter Learn mode:** With the row still selected, click the **Learn New Assignment** button at the bottom right of the window. The button highlights blue and Logic now listens for any incoming MIDI message.

5. **Send the CC from your MCP client** (e.g. Claude):
   > "Send CC 30 value 127 on channel 16 via the keycmd port."

   That maps to:
   ```jsonc
   logic_midi.send_cc {
     "controller": 30,
     "value": 127,
     "channel": 16,
     "port": "keycmd"
   }
   ```
   Logic should immediately display `Ch 16 / Controller #30` next to the command and exit Learn mode automatically.

6. **Save the assignment:** Click `Save As…` (or `Save` if you've saved this set before). Logic 12.2 stores assignments in its own binary `.logikcs` format inside the user `Key Commands` folder; **do not** try to edit it manually.

7. **Verify:** Send the CC again — Logic should perform Undo on the focused window. If nothing happens, return to step 4 and re-bind (Logic occasionally drops the first capture on a freshly-created port).

### 4.3 Manual MIDI Learn — Example 2: `Track > New Audio Track` (CC 20, Ch 16)

> Same flow, repeated to confirm the pattern.

1. Already approved the channel from §4.2 step 1? Skip. Otherwise approve as above.

2. `Logic Pro → Key Commands → Edit…` (⌥K). Search `New Audio Track`. Click the row.

3. Click **Learn New Assignment**.

4. From your MCP client:
   ```jsonc
   logic_midi.send_cc {
     "controller": 20,
     "value": 127,
     "channel": 16,
     "port": "keycmd"
   }
   ```

5. Click `Save Assignments`.

6. Verify by repeating the send — Logic should create a new audio track each time.

### 4.4 Channel cheat-sheet

`channel: 16` in MCP corresponds to **Ch 16** in Logic's UI (1-based). Pre-v3.1.6 the wire encoding was 0-based (`channel: 15` = Logic Ch 16); v3.1.6 normalizes the contract. See `CHANGELOG.md §[3.1.6]` for the migration table.

---

## 5. Install Scripter Insert (optional — for plugin parameter control)

Enables `set_plugin_param` for fine-grained plugin automation via CC 102-119.

1. In Logic Pro, select a Software Instrument track
2. Click the **MIDI FX** slot on the channel strip → select **Scripter**
3. In the Scripter window, click the **Script Editor** tab
4. Paste the contents of `Scripts/LogicProMCP-Scripter.js` into the editor
5. Click **Run Script**

Approve:

```bash
LogicProMCP --approve-channel Scripter --approval-note "Validated insertion on target track"
```

---

## 6. Verify Everything

Ask Claude:

> "Check Logic Pro MCP health."

Expected — all 7 channels `ready`:

```
- Accessibility ✓
- AppleScript ✓
- CoreMIDI ✓
- MCU ✓
- MIDIKeyCommands ✓ (if you completed step 4)
- Scripter ✓ (if you completed step 5)
- CGEvent ✓
```

If any channel is `manual_validation_required`, return to step 4 or 5 and complete the approval.

### 6.1 Production-readiness smoke checks

For release-candidate validation, run a release build and then exercise one readback-sensitive write in each risky family:

```bash
swift test
swift build -c release
```

In a live Logic Pro 12.2 project, verify:

- `logic_transport set_tempo` returns an Honest Contract response with `verified:true` or a hard State C error; do not proceed on unverified fallback output.
- `logic_midi import_file` uses a real `.mid` under `/tmp/LogicProMCP/` and waits for `verified:true` before the next import.
- `logic_project save_as` returns `verified:true` and includes `observed` / `observed_mtime` for the `.logicx` package.
- `logic://project/info` reports live/cache/project-file/default provenance honestly; visible track rows are not a whole-project track-count substitute.

---

## Uninstall

```bash
Scripts/uninstall.sh

# Or manually:
sudo rm /usr/local/bin/LogicProMCP
claude mcp remove logic-pro
Scripts/uninstall-keycmds.sh   # restores original Key Commands
```

Inside Logic Pro, open **Control Surfaces → Setup…**, select the Mackie Control device, and press Delete.

---

## What's Next

- [API Reference](API.md) — full MCP tool surface
- [Troubleshooting](TROUBLESHOOTING.md) — common issues
- [Architecture](ARCHITECTURE.md) — how the 7-channel design works
