# Logic Pro MCP — full-surface exercise & bug report (demo QA)

**Environment:** logic-pro-mcp `main @ 8586d9f` (v3.9.x) · Logic Pro 12.3 · macOS 26.3 (Tahoe) · Apple Silicon
**Method:** every dispatcher command + every resource was driven against a live Logic project via JSON-RPC stdio, with per-call hang/crash detection and full raw-response capture. Each result classified: **verified** (State A, confirmed by readback) · **attempted-unverified** (State B, sent but not readback-verified — by design for send-only/no-readback ops) · **unsupported/honest-wall** (State C fail-closed) · **failed** (crash/hang/false-success).

## Coverage summary
- **Tools:** 10 / 10 exercised · **Resources:** 18 / 18 read · **Commands:** ~90 unique commands driven.
- **0 crashes, 0 hangs** across the full sweep (server stayed alive through ~90 commands).
- Classification (sweep batch): **17 verified**, **60 attempted-unverified (State B by design)**, **14 unsupported/honest-wall**, **0 hard failures**.
- 21 responses were bug-flagged and adversarially triaged → **4 confirmed bugs filed**, the remainder were correct honest-contract behavior or caller param mistakes (verified by re-running with correct params).

## Verified working (State A, readback-confirmed) — used in the demo
- `transport.set_tempo` (82 BPM), `goto_position`, `goto_bar`, `toggle_cycle`
- `tracks.record_sequence` (SMF import → new Studio Grand track, region readback), `create_instrument`, `create_audio`, `create_external_midi`, `create_drummer`, `select`, `rename`, `mute`, `solo`, `arm`, `arm_only`, `set_instrument` (category+preset)
- `mixer.set_volume`, `set_pan`
- `plugins.get_inventory` (drift-safe insert chain, hc_schema 2)
- `navigate.goto_bar`, `set_zoom`
- `transport.record` / `stop`, `project.save` (AppleScript), `audio.analyze_file` (loudness/peak/duration)
- `midi.mmc_locate`
- **Bounce:** `logic_project.bounce {confirmed:true}` opens the verified native `File ▸ Bounce ▸ Project or Section…` dialog; that path rendered the valid AIFF used for the demo audio.

## Honest State-B (attempted, readback-unavailable — not failures)
Send-only or cgevent ops that correctly report "sent, unverified": all `midi.send_*` / `play_sequence` / `step_input` / `mmc_*`, `edit.*` (undo/redo/cut/copy/paste/split/join/quantize/select_all/bounce_in_place), `navigate.toggle_view` / `zoom_to_fit`, `tracks.duplicate` / `set_automation`, `transport.rewind` / `fast_forward` / `toggle_metronome`, `mixer.set_master_volume` (MCU, no readback). `logic://mixer` returns `ax_poll` strips **after `refresh_cache`** (the read-only resource reflects the poller cache; `mixer_not_visible` before a poll is expected).

## Honest walls (State C, correctly fail-closed — NOT bugs)
`transport.set_cycle_range` (no numeric cycle locator on 12.x), `navigate.rename_marker` (documented not_implemented), `transport.toggle_autopunch` (Autopunch not in Control Bar — with recovery hint), `mixer.set_plugin_param` (Scripter not installed on this host).

## Bugs filed and fixed by v3.11.0 (4)
| # | Issue | Severity | Summary |
|---|-------|----------|---------|
| [#253](https://github.com/MongLong0214/logic-pro-mcp/issues/253) | help category gap | p3 | Fixed in v3.11.0: `logic_system.help` accepts the real `audio` and `plugins` categories and reports them in the valid-category list. |
| [#254](https://github.com/MongLong0214/logic-pro-mcp/issues/254) | marker surface | p2 | Fixed in v3.11.0: `create_marker` uses Logic's native Navigate menu and `logic://markers` preserves unreadable/cache state instead of promoting a false empty list. |
| [#255](https://github.com/MongLong0214/logic-pro-mcp/issues/255) | keycmd routing | p3 | Fixed in v3.11.0: `toggle_count_in` and `toggle_step_input` use native Control-Bar/menu paths with readback where available. |
| [#256](https://github.com/MongLong0214/logic-pro-mcp/issues/256) | bounce routing | p2 | Fixed in v3.11.0: `project.bounce` prefers the native File menu and verifies that the Bounce dialog opened. |

Root theme for #254/#255/#256 was that several commands routed only through an unbound Logic key command and failed with `channels_exhausted` instead of using the available native menu/Control-Bar path. v3.11.0 resolves the shipped paths with deterministic native UI routes; `navigate.rename_marker` remains a separate `not_implemented` honest wall.

## Demo composition (what's on screen)
82 BPM, D minor lofi. `record_sequence` × 3 → **Chords** (Dm7–B♭maj7–Gm7–A7), **Bass** (D–B♭–G–A roots), **Lead** (D-pentatonic motif), all Studio Grand piano; **Drummer** (SoCal). Piano roll opened on Chords; real-time playback. Audio bed = Logic's own bounce of this loop (11.7 s, 48 kHz/24-bit, −0.1 dBFS peak).

## v3.12.0 note

The Homebrew bounce/export regression reported after this QA round (missing `logic_variants.py`, [#427](https://github.com/MongLong0214/logic-pro-mcp/issues/427)) is fixed in v3.12.0 with an import-closure release gate; coordinate-free actuation and the locale-neutral modal classifier shipped in the same release.
