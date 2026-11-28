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

Check the MCP client logs, confirm the command path, and run `LogicProMCP --check-permissions`. macOS TCC permissions apply to the server's responsible process: the process named as the `TCC principal`, which is either the app that launches it or the LogicProMCP binary itself. See [Which process needs the permission](#which-process-needs-the-permission).

### Concurrent large reads appear to time out ("no response")

The server speaks newline-delimited JSON-RPC over a single stdout pipe, and it serializes writes (one response frame is fully flushed before the next starts — frames never interleave or corrupt). If a client fires several large reads at once — e.g. `logic://library/inventory`, `logic_tracks.scan_library` in disk mode, `logic://project/audit` — and does not drain stdout while it keeps sending, the pipe back-pressures: later responses queue behind the one being flushed and can exceed a short client deadline, looking like "no response." Run alone, each returns quickly.

This is client-side backpressure, not a server stall. Mitigations:

- Drain stdout concurrently with sending (read responses on a separate thread/task), as any correct MCP stdio client does.
- Or serialize very large reads (await each before issuing the next).
- Prefer resource reads for polling large state instead of firing many in parallel.

The server produces every response, complete and well-formed, under concurrent load (covered by `Issue220ConcurrentLargeReadTests` and the live-e2e pipelined-read check).

## Permissions

### Which process needs the permission

One rule covers Accessibility, PostEvent, Automation to Logic Pro and Automation to System Events: grant the process that `logic_system permissions`, called from the affected client, or `LogicProMCP --check-permissions` run the way that client runs it, names as the **TCC principal**. Do not guess it from the launcher. macOS checks these permissions against the server's *responsible process*, and the launcher decides which process that is. Some clients start MCP servers with responsibility disclaimed, so the principal is the LogicProMCP binary itself and a grant on the client app does not apply. Other clients leave it inherited, so the principal is the client app.

The principal is reported as a public label only: `LogicProMCP` with an install kind (`homebrew`, `source build`, `app bundle` or `other install`), a bundle identifier from a short list of known clients such as Terminal, or `another executable` / `another application`. It is never a directory or a copied name. You see it as the `TCC principal:` line, as `tcc_principal` and `tcc_principal_is_self` in `logic_system permissions`, and in the evidence of `permissions.launch_context` in `doctor`.

Procedure:

1. From the affected client, read the principal label. For a desktop client, ask it to run `logic_system permissions`; for a terminal client, run `LogicProMCP --check-permissions` in it. A run from another app measures that app, not the client that is failing.
2. Keep the entries that are already granted. Remove an entry only when you know it belongs to a binary no client launches any more, such as an old Homebrew Cellar version. Never delete granted entries to start over.
3. In **System Settings -> Privacy & Security**, make the entry for that principal effective under **Accessibility** and under **Automation** (Logic Pro and System Events; PostEvent is reported separately, so read its line too).
   - **Accessibility**: if the principal is missing, add it with **+** (Cmd-Shift-G pastes a path), then enable it.
   - **Automation**: macOS has no **+** here. An entry appears only after that principal has asked for Automation once. If the entry for the named principal is listed, enable its toggles. If it is absent, nothing in System Settings can add it, and a prompt is not guaranteed: some features check consent without prompting and stop before asking. If the entry is absent and no system prompt appears, STOP. There is nothing more to do in System Settings. Report it in the issue with the diagnosis output (the principal line and the four states). LogicProMCP does not automate or answer permission prompts.
   - If the principal is the LogicProMCP binary itself, find its path locally in your own Terminal while the client is running, and prove which client started it. List processes with `ps -axww -o pid=,ppid=,comm=` (the `-ww` flag removes the width limit, so a long path is not cut). Find the row whose command ends in `/LogicProMCP`. Its second number is its parent pid: look that pid up in the first column of the same listing and confirm that the row is the affected client's own process. Only then use the `LogicProMCP` path from that row. The path is never shown in MCP output. Do not use `which LogicProMCP`: Terminal may resolve a different copy. A match alone proves nothing, because another client's server, or a copy left running in the background, can be the only one listed.
   - **Stop rule.** If the listing shows no `LogicProMCP` row, the parent pid is not the affected client's process, or the association cannot be established, or if the principal line reads a generic label (`another executable`, `another application`) or an unresolved one (`unidentified process`, or `tcc_principal` unresolved), STOP and change nothing. Share the `--check-permissions` output in the issue instead.
4. Verify from that same client: run `logic_system permissions` (or `--check-permissions`) again and read the same principal line and the four states.

A Homebrew upgrade installs a new `Cellar/<version>` path and the release binary carries only an ad-hoc signature, so a grant for one version does not carry over to the next and the old entry stays in the list looking enabled. Repeat the procedure after each `brew upgrade logic-pro-mcp`.

What is not measured: behaviour on macOS 27 is reported by users and has not been reproduced by the maintainers. One reporter on 27.2.1 still saw denial after adding the binary by hand. This procedure is not claimed to fix macOS 27; the diagnosis output (the principal line, its `tcc_principal_is_self` flag and the four states) is what is needed to investigate further, so include it when you report a problem. Whether the Accessibility switch also covers PostEvent on macOS 27 is likewise not measured.

### Accessibility denied

Apply the rule in [Which process needs the permission](#which-process-needs-the-permission): grant Accessibility to the reported `TCC principal`.

### Automation denied or not verifiable

Launch Logic Pro once, then under **Privacy & Security -> Automation** enable **Logic Pro** for the reported `TCC principal` (see [Which process needs the permission](#which-process-needs-the-permission)). When the principal is the LogicProMCP binary itself, the entry to enable is that binary, not the launcher app. If the principal has no Automation entry at all, step 3 of the procedure applies: that entry appears only after the principal has asked once, and it cannot be added by hand.

`--check-permissions`, `logic_system health`, and `doctor` report each TCC target as one of three states — read them differently:

- **`not_granted`**: the probe ran and macOS denied it. Grant Automation as above.
- **`not_verifiable`**: the probe itself could not complete (it timed out or failed to spawn). This is an infrastructure failure, **not** a denial — do not assume the permission is missing. Re-run the check on a responsive session; if it persists, investigate what is blocking the probe (a wedged Logic UI, a stuck modal, or a sandbox that prevents spawning `osascript`) rather than re-granting an already-correct permission.
- **`granted`**: verified working.

(Before v3.8.0 a `not_verifiable` outcome was mis-reported as a false "Automation NOT GRANTED".)

### `-1743` / System Events Automation denied

`-1743`, `errAEEventNotPermitted`, or "not authorized to send Apple events" from `tell application "System Events"` means the reported `TCC principal` is denied Automation to System Events. This is a permission gap on that principal, not a Logic Pro limitation, and Logic Pro Automation being granted is separate and not sufficient. System Events Automation is part of both `--check-permissions` and doctor readiness.

Fix it by applying the rule in [Which process needs the permission](#which-process-needs-the-permission): under **System Settings -> Privacy & Security -> Automation**, enable **System Events** for the process the principal line names, which is the LogicProMCP binary itself when `tcc_principal_is_self` is `true`. Switching to another client helps only when the principal measured from that client is that client. Run `logic_system permissions` from the other client: if its principal line names the client app (`tcc_principal_is_self` is `false`), the grant on that client applies. If it names the LogicProMCP binary (`tcc_principal_is_self` is `true`), the grant belongs to the binary, and a grant on the client does not change that. A client that disclaims responsibility is not covered by its own grant.

### PostEvent denied

`permissions.post_event_access=fail` means CGEvent-family operations cannot post trusted keyboard or click events for the reported `TCC principal`. Apply the rule in [Which process needs the permission](#which-process-needs-the-permission), then rerun the check from the same client:

```bash
LogicProMCP --check-permissions
LogicProMCP doctor --json
```

### Permissions look granted but another client still fails

TCC permissions belong to the server's responsible process, which depends on the launcher (see [Which process needs the permission](#which-process-needs-the-permission)). A Terminal-run doctor can pass while Claude Desktop, launchd, or another wrapper is evaluated as a different principal. Check `permissions.launch_context` (its `tcc_principal` evidence) and `permissions.tcc_cross_context` in `LogicProMCP doctor --json`, then rerun the check from the app that will actually spawn the server.

If `permissions.tcc_cross_context` is `skipped`, the live permission probes remain authoritative. The skipped `reason` tells you why the database enrichment could not answer: `full_disk_access_unavailable`, `tcc_query_unavailable`, `tcc_schema_mismatch`, or `principal_not_found`.

### Stale installed binary or helper assets

If `install.binary_inventory=warn`, a canonical installed `LogicProMCP` binary has a different static version from the running doctor. Reinstall or upgrade the package and refresh the MCP registration:

```bash
brew update
brew reinstall logic-pro-mcp
claude mcp add --scope user logic-pro -- LogicProMCP
```

If `install.share_dir=warn`, packaged helper assets are missing from the resolved share directory. Reinstall the package; source-build runs may show `share_dir_unresolved`, which is expected unless you set `LOGIC_PRO_MCP_SHARE_DIR`.

## Logic Pro State

### Health says Logic is not ready

Doctor reports a stopped application, missing visible project window, or measured blocking dialog
as a terminal unavailable state with zero human-intervention requests. It does not launch/focus
Logic, dismiss a dialog, create a project, or ask for a manual retry.

### Positioning refuses before writing

When `goto_position` returns `ax_write_failed` with `frontmost_preparation` set to `activation_refused` or `activation_timed_out`, the channel could not establish that Logic owns the keyboard. `record_sequence` preserves this positioning failure before MIDI import; a router fallback can wrap it in `channels_exhausted`/`last_error`. Read `frontmost_observation.reason` and each channel's completed trace: `window_list_unavailable`, `keyboard_window_absent`, `keyboard_owner_unavailable`, `keyboard_bundle_unavailable`, `keyboard_owner_not_logic` or `focused_application_mismatch` distinguish the last gate observation. CG windows are read before AX focus; the first normal/modal window must have a readable Logic owner bundle, and readable focus must name that owner. An unavailable `focus_read` alone retains the window-based decision, rather than proving a permission failure. Titles, project paths and raw AX errors are not included.

The operation terminates without asking for activation, dialog dismissal, blind Escape, a guard
bypass, or permission changes. Preserve the sanitized support bundle and its separate channel
observations as the failed attempt's evidence. Passed permission checks do not prove keyboard
ownership or recording success, and an activation timeout alone does not establish a Logic 12.4
incompatibility. The diagnostics describe the observation that decided that attempt, not a later
resample or a guarantee that another attempt is ready.

### `select` returns `readback_mismatch` on Logic 13

Logic 13 ignores the track-header selection write, so `select` (and `mute`, `rename` by index, which select first) goes through the main Mixer, and only in Tracks view with every type filter on and the strips' names matching the track headers row by row. `mixer_refusal` names which of these did not hold; nothing was written to the Mixer and the selection stayed where it was. Show the Mixer in Tracks view with all filters on and try again. State C `unsafe_focus_for_synthetic_key` means a text field, usually an open track rename, has the focus: finish or cancel it first.

### `logic://tracks` shows placeholders

Make the main Tracks area visible and wait for one refresh. Placeholder rows are treated as untrusted and should not be used for writes.

### `logic://markers` is empty

On Logic 12.2, marker reads require the marker list surface to be available. An empty list can be the honest result when the UI surface is closed or not exposed.

### `logic://project/info.trackCount` is `0` or lower than visible tracks

Refresh `logic://tracks` first. Current builds promote trusted live track-cache counts into project info when saved metadata is incomplete.

### `logic://project/info.sampleRate` does not match the saved project

Save the project, then read `logic://project/info` again. Current builds prefer a positive `SampleRate` from the validated current project's saved `MetaData.plist`; a fresh live transport value is used only when that saved field is missing or invalid. If neither source is available, the response retains the `44100` struct default. The resource does not write the file-derived value into shared cache state or combine it with metadata from a different project path.

## MCU and Mixer

### Mixer writes return `channels_exhausted`

Register the Mackie Control surface and set both ports to `LogicProMCP-MCU-Internal`; see [SETUP.md](SETUP.md).

### Mixer writes return `echo_timeout_500ms`

Logic accepted the host write path but did not echo enough feedback for MCU verification. Confirm MCU registration, make the mixer visible, and read `logic://mcu/state`.

### Mixer values do not update

Read `logic://mixer` after the write. `set_volume` and `set_pan` use visible-strip AX readback; `set_master_volume` depends on MCU feedback. A `verified` write with `reached_exact: false` landed within the detent tolerance but not on the raw position nearest the request: the `AXValue` fine phase was skipped, could not read the slider, was refused, stopped when a write did not bring the slider closer, or used all its writes. `fine_steps: 0` does not tell these apart, since it counts accepted write calls and a skipped phase, a failed first read or a first refused write all leave it at zero. State B `readback_mismatch` with a `reason_detail` about moving away means a fine write left the slider further from the target; it was not restored. `observed_raw` is where it stopped, or null when the read after the fine phase failed; the `reason_detail` then says so. `set_send` is not exposed (State C `command_not_exposed`), so there is no send write to verify.

## MIDI

### Duplicate server launches and MIDI ownership

Claude Desktop may launch two copies of one MCP configuration: one for chat and another for Code/Cowork. Separate clients can also start competing copies. The server reserves its virtual MIDI port group for one process before creating individual endpoints, so updated instances do not split CoreMIDI, MCU, Key Commands and Scripter ports between them. The other process reports that it did not acquire the virtual MIDI port group; its MIDI operations remain unavailable/degraded, while unrelated channels retain their own readiness checks.

Use `logic_system health` and the client logs to identify ownership failures. Stop competing launches through their clients, then restart the intended server. A losing process keeps its refused claim until it exits: the owner's exit alone does not silently enable MIDI in the loser. OS creation failures, unreadable endpoint censuses and existing foreign/stale endpoints still refuse; a group reservation does not certify that all endpoints were created. Do not add duplicate Logic control surfaces, change permissions, delete lock files or kill CoreMIDI to work around a second launcher. An older already-running server does not participate in the new group claim, so stop old copies before evaluating ownership after an update.

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

If `record_sequence` returns `operation_timeout`, inspect `import_started`. `false` means the deadline won before the import boundary and the server blocked the import plus all later relocation writes. `true` means the import had already been committed to start; Logic may still add the track and MIDI region, so do not retry blindly. The timeout deliberately does not kill an active `osascript`, because interrupting it between the menu action and Import confirmation can leave Logic's file panel open.

## MIDI Key Commands and Scripter

### `unattended_unavailable`

Key Commands and Scripter mapped operations cannot establish Logic-side setup or outcome readback
programmatically. The server leaves them unavailable for unattended routing and does not request an
operator assertion. Legacy approval records may still be listed for compatibility, but do not make
either channel ready. Raw MIDI bypass calls remain separate and may use a ready virtual transport.

### Key Commands do not trigger

Logic 12.2+ does not reliably import the legacy `.plist`. The remaining keycmd-only paths listed in
[SETUP.md](SETUP.md) therefore terminate as unavailable instead of requesting manual MIDI Learn.

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

If permissions look wrong after reinstalling, remove only the entries for binaries no client launches any more, then run the procedure in [Which process needs the permission](#which-process-needs-the-permission) from the affected client and grant the principal its line names. After a reinstall that principal can be the LogicProMCP binary at its new path, not the client app, so do not grant the launcher by default.

## Still stuck?

Join the official Logic Pro MCP Discord for real-time setup help and triage: [https://discord.gg/4M3s79DBzz](https://discord.gg/4M3s79DBzz).

For a reproducible bug, open a [GitHub Issue](https://github.com/MongLong0214/logic-pro-mcp/issues) with `LogicProMCP doctor` output and `LOG_LEVEL=debug` logs — that stays searchable and is the canonical tracker.

## bounce/export fails with `ModuleNotFoundError: No module named 'logic_variants'`

Your install is v3.11.0 from Homebrew or the pinned shell installer: that release packaged the bounce helpers without their shared `logic_variants.py` module ([#427](https://github.com/MongLong0214/logic-pro-mcp/issues/427)). Upgrade to v3.12.0 or later (`brew update && brew upgrade logic-pro-mcp`, or re-run the pinned installer with the v3.12.0 pins). (The v3.12.0 binary's `doctor` detects this state — it reports the share directory as incomplete when `logic_variants.py` is missing; the v3.11.0 binary predates that check.) The failure is fail-closed — no partial artifact is written and the project is untouched.

## `setup_arm_key` returns `consent_required`, `verify_environment_unavailable`, or `chord_conflict`

- `consent_required`: pass `consent: true`. The operation mutates Logic's global key commands and never runs implicitly.
- `verify_environment_unavailable`: no selectable track was available to functionally test the chord; open a project with at least one track and retry. Nothing was changed.
- `chord_conflict`: the chord is already assigned to another command. The setup never steals an existing binding — choose a different chord via `LOGIC_PRO_MCP_ARM_KEYCODE` / `LOGIC_PRO_MCP_ARM_MODIFIERS`, or free the chord in Logic ▸ Key Commands and retry.
