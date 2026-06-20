# Demo Recording QA Failure Issue Candidates

Date: 2026-06-18
Scope: Failures and non-State-A behavior observed while producing the Reddit demo videos and Berlin hard-techno follow-up captures, primarily v7-v27.

Source evidence:

Note: the `docs/media/reddit-dudddee-*` and related capture/render artifacts
below are historical source names from the QA pass. They are no longer retained
as tracked repo media after the docs/media cleanup; the GitHub issues preserve
the actionable findings.

- `docs/media/reddit-dudddee-actual-usage-v7-transcript.json`
- `docs/media/reddit-dudddee-english-ui-actual-v8-transcript.json`
- `docs/media/reddit-dudddee-english-ui-actual-v9-transcript.json`
- `docs/media/reddit-dudddee-real-qa-demo-v10-transcript.json`
- `docs/media/reddit-dudddee-varied-track-types-v11-transcript.json`
- `docs/media/reddit-dudddee-actual-techno-ui-v14-transcript.json`
- `docs/media/reddit-dudddee-actual-techno-ui-v15-transcript.json`
- `docs/media/reddit-dudddee-rich-techno-ui-v17-transcript.json`
- `docs/media/reddit-dudddee-fresh-truthful-ui-v20-transcript.json`
- `docs/media/reddit-dudddee-fresh-truthful-ui-v22-transcript.json`
- `docs/media/reddit-dudddee-audio-fix-v23-transcript.json`
- `docs/media/reddit-dudddee-rich-bounce-v24-transcript.json`
- `docs/media/reddit-dudddee-berlin-hard-techno-v25-transcript.json`
- `/Users/isaac/.openclaw/workspace/out/berlin-hard-techno-logic-v27-transcript.json`
- `/Users/isaac/.openclaw/workspace/memory/2026-06-18.md`
- `/Users/isaac/.openclaw/workspace/memory/2026-06-19.md`

Registration status: created on GitHub as bug issues on 2026-06-18 and follow-up bug issues/comments on 2026-06-19.

GitHub issues:
- #33 `Demo QA: Track resource returns empty after visible live track creation` - https://github.com/MongLong0214/logic-pro-mcp/issues/33
- #34 `Demo QA: Track rename fails in live Logic UI` - https://github.com/MongLong0214/logic-pro-mcp/issues/34
- #35 `Demo QA: Track creation commands fire key commands but are not verified` - https://github.com/MongLong0214/logic-pro-mcp/issues/35
- #36 `Demo QA: Tempo setting can overshoot and still report success` - https://github.com/MongLong0214/logic-pro-mcp/issues/36
- #37 `Demo QA: Region readback fails in real Logic UI sessions` - https://github.com/MongLong0214/logic-pro-mcp/issues/37
- #38 `Demo QA: Plugin and insert inventory cannot locate mixer/insert subtree in the demo state` - https://github.com/MongLong0214/logic-pro-mcp/issues/38
- #39 `Demo QA: Mixer volume and pan writes are unverified and may target the wrong strip` - https://github.com/MongLong0214/logic-pro-mcp/issues/39
- #40 `Demo QA: Key-command-backed edit/navigation commands lack readback` - https://github.com/MongLong0214/logic-pro-mcp/issues/40
- #41 `Demo QA: Transport stop AX lookup fails in some real UI states` - https://github.com/MongLong0214/logic-pro-mcp/issues/41
- #42 `Demo QA: record_sequence is not reliable enough to claim as a working feature` - https://github.com/MongLong0214/logic-pro-mcp/issues/42
- #43 `Demo QA: Instrument/patch assignment is not a verified product workflow` - https://github.com/MongLong0214/logic-pro-mcp/issues/43
- #44 `Demo QA: Real Logic audio was not captured; guide audio was synthesized` - https://github.com/MongLong0214/logic-pro-mcp/issues/44
- #45 `Demo QA: Fresh Logic project bootstrap is brittle for automation` - https://github.com/MongLong0214/logic-pro-mcp/issues/45
- #46 `Demo QA: Video rendering pipeline had non-product failures` - https://github.com/MongLong0214/logic-pro-mcp/issues/46
- #47 `Demo QA: Tempo write can fail to locate the tempo control in fresh real UI sessions` - https://github.com/MongLong0214/logic-pro-mcp/issues/47
- #48 `Demo QA: Transport play and record AX lookup fails in real UI states` - https://github.com/MongLong0214/logic-pro-mcp/issues/48
- #49 `Demo QA: MIDI import rejects valid /tmp LogicProMCP paths after macOS path normalization` - https://github.com/MongLong0214/logic-pro-mcp/issues/49
- #50 `Demo QA: Guide audio misrepresents visible Logic instrument state` - https://github.com/MongLong0214/logic-pro-mcp/issues/50
- #51 `Demo QA: set_cycle_range cannot set numeric locators in real Logic UI` - https://github.com/MongLong0214/logic-pro-mcp/issues/51
- #52 `Demo QA: Reusing polluted Logic sessions hides fresh-project truth` - https://github.com/MongLong0214/logic-pro-mcp/issues/52
- #53 `Demo QA: create_instrument timeout can pollute fresh capture track numbering` - https://github.com/MongLong0214/logic-pro-mcp/issues/53
- #55 `Demo QA: Track arm/arm_only reports success while record-enable readback is unavailable` - https://github.com/MongLong0214/logic-pro-mcp/issues/55
- #56 `Demo QA: Transport state readback can remain stale after visible Stop and MCP stop` - https://github.com/MongLong0214/logic-pro-mcp/issues/56
- #57 `Demo QA: Unverified go-to-beginning can let live MIDI record at stale high bar positions` - https://github.com/MongLong0214/logic-pro-mcp/issues/57
- #58 `Demo QA: Free Tempo Recording modal can interrupt fresh live-record captures` - https://github.com/MongLong0214/logic-pro-mcp/issues/58
- #59 `Bug: Logic 12.2 AX readback can return placeholder tracks and stale cycle state` - https://github.com/MongLong0214/logic-pro-mcp/issues/59 (closed by PR #54)

Resolution note for v3.6.0 candidate:
- PR #54 / issue #59 resolves the `logic://tracks` placeholder-mode root cause, descendant-based track type inference gap, and stale cycle readback path with focused AX regression tests, release build, full `swift test --no-parallel` `1388/1388`, and live read-only probe evidence (`source:"ax_live"`, `placeholder_count:0`, `unknown_type_count:0`).
- The demo-specific issues below remain preserved as the original QA findings. Some acceptance criteria are now partially or fully covered by the PR #54 fix, but the document keeps the observed failure history for regression context.

## P0 Product Correctness

### 1. Track resource returns empty after visible live track creation

Resolution status:
- Root cause class closed by issue #59 / PR #54 for Logic 12.2 header-description drift and stale cycle readback.
- Current v3.6.0 candidate evidence shows `logic://tracks` returning real `ax_live` rows with no placeholders and no unknown track types in the tested Logic 12.2 session.

Observed behavior:
- In v10, v11, and v14, `logic://tracks` returned `0 item(s)` even after Logic showed created tracks and recorded regions.
- Per-track region reads such as `logic://tracks/0/regions` also returned empty arrays.

Evidence:
- v10: `readback logic://tracks` -> `0 item(s) read`
- v11: `readback logic://tracks` -> `0 item(s) read`
- v14: `readback logic://tracks` -> `0 item(s)`

Why it matters:
- This blocks verification for track creation, track rename, track type, region placement, and public demo claims.

Acceptance criteria:
- After creating tracks in Logic Pro 12.2 English UI, `logic://tracks` returns the visible track list with stable index, name, and type.
- Track count readback is usable as a post-write verification gate.
- Empty readback must be State B/C with a specific UI-detection reason, not a silent empty success.

### 2. Track rename fails in live Logic UI

Observed behavior:
- `logic_tracks.rename` repeatedly failed with `element_not_found`.
- The API could not locate the track name field for visible tracks.

Evidence:
- v9: `logic_tracks.rename Kick/Bass/Stab/Hat` -> `error=element_not_found`
- v14: `logic_tracks.rename Kick/Bass/Stab/Hats` -> `error=element_not_found`
- Error detail: `name field for track N not located`

Why it matters:
- We could not claim visible track naming in the demo.
- Techno layers stayed as default Logic names unless manually patched or edited.

Acceptance criteria:
- Rename works for track indexes 0..N in Logic Pro 12.2 English UI.
- Rename verifies through `logic://tracks` or an equivalent AX readback.
- If the name field is not accessible, return a structured unsupported/UI-drift state with no success wording.

### 3. Track creation commands fire key commands but are not verified

Observed behavior:
- `create_instrument`, `create_drummer`, `create_audio`, and `create_external_midi` returned `success=true` but `verified=false`.
- Reason was usually `readback_unavailable`.
- Several flows required an extra manual/UI confirmation of the Create New Track dialog.

Evidence:
- v8/v9/v10/v11/v14: `logic_tracks.create_*` -> `success=true verified=False reason=readback_unavailable`
- v11 script added `confirm_track_dialog()` after create commands.
- v17: 11 rich-techno `track.create.v4_*` calls returned State B while the final demo relied on visible Logic UI plus live recording for proof.

Why it matters:
- The command may have fired, but the API could not prove the intended track type was created.
- This forced the video script to rely on visible UI and manual confirmation rather than product-level verification.

Acceptance criteria:
- Track creation returns State A only after a verified track-count/type delta.
- Commands either handle the Create New Track dialog internally or report a clear waiting-for-user/dialog state.
- Response includes observed track index/type/name when verified.

### 4. Tempo setting can overshoot and still report success

Observed behavior:
- `set_tempo 128` sometimes reported `success=true verified=false`.
- The fallback path used 10 BPM slider increments and observed `130` instead of requested `128`.

Evidence:
- v11: `logic_transport.set_tempo 128.0` -> `readback_mismatch`, requested 128, observed 130.
- v14: `logic_transport.set_tempo 128` -> `readback_mismatch`, requested 128, observed 130.
- Response note: `typed entry didn't commit`.

Why it matters:
- Tempo is a core music state. Overshooting the requested tempo cannot be treated as success.

Acceptance criteria:
- Tempo writes are exact or fail closed.
- No path reports `success=true` for an observed tempo mismatch.
- Response includes requested, observed, and method.

### 4b. Tempo write can fail to locate the tempo control in fresh real UI sessions

Observed behavior:
- In v15, `logic_transport.set_tempo 128` failed with `element_not_found`.
- This is distinct from the earlier overshoot/readback mismatch case because the command failed at control discovery.

Evidence:
- v15: `logic_transport.set_tempo 128` -> `error=element_not_found`

Why it matters:
- Fresh-project demo flows cannot rely on preconfigured tempo or manual tempo setup.
- Tempo is a core musical state and must either verify exactly or fail closed with a recovery hint.

Acceptance criteria:
- `set_tempo` works from a fresh Logic Pro 12.2 English UI project after the Create New Track dialog is cleared.
- The response includes requested tempo, observed tempo, method, and UI landmarks when lookup fails.
- No path reports success unless the requested tempo equals observed tempo.

### 5. Region readback fails in real Logic UI sessions

Observed behavior:
- `logic_project.get_regions` failed after real UI recording sessions.
- Error was `channels_exhausted` with `Track Content group not found`.

Evidence:
- v10/v11/v14: `logic_project.get_regions` -> `error=channels_exhausted`
- v11 per-track region resources returned empty arrays even after regions were visible.

Why it matters:
- This blocks the core claim "MCP created MIDI regions in Logic" from being verified after writes.

Acceptance criteria:
- Region extraction works in Logic Pro 12.2 English UI with Library, Inspector, Session Player, and Tracks areas visible.
- The parser returns visible MIDI/Drummer/audio regions with track index, start, and end.
- Failure includes scanned UI landmarks and a recovery hint.

### 6. Plugin and insert inventory cannot locate mixer/insert subtree in the demo state

Observed behavior:
- `logic_plugins.get_inventory` returned Honest Contract State B.
- Reason: `ax_subtree_unreadable`, `mixer area was not locatable in the AX tree`.
- Initial `logic://mixer` often returned `0 mixer strip(s)` with `data_source=mixer_not_visible`.

Evidence:
- v7/v10/v11: `logic_plugins.get_inventory track 0` -> `readback_unavailable`
- v10/v11: initial `logic://mixer` -> `0 mixer strip(s)`

Why it matters:
- Insert-chain inventory and verified plugin apply-back cannot be demoed in normal arrange-window usage.

Acceptance criteria:
- Inventory can reveal or navigate to the mixer when needed, then read target track inserts.
- If mixer is not visible, the response says so directly and offers the required recovery path.
- State A requires observed insert-chain readback.

## P1 Mutating Command Verification

### 7. Mixer volume and pan writes are unverified and may target the wrong strip

Observed behavior:
- `logic_mixer.set_volume track 0` and `logic_mixer.set_pan track 0` returned `success=true verified=false`.
- Reason: `echo_timeout_500ms`; observed AX and MCU values were null.
- Later mixer readbacks did not provide a clean proof that requested track 0 received the requested values.

Evidence:
- v10/v11: `logic_mixer.set_volume track 0` -> `echo_timeout_500ms`
- v10/v11: `logic_mixer.set_pan track 0` -> `echo_timeout_500ms`

Why it matters:
- Mixer mutation is high-risk. A write with no echo/readback must not be marketed as working.

Acceptance criteria:
- Volume/pan write either returns State A with observed target strip value or fails closed.
- Response includes target strip identity, observed before/after, and verification source.
- Add regression coverage for stale MCU echo and wrong-strip prevention.

### 8. Key-command-backed edit/navigation commands lack readback

Observed behavior:
- Several commands are only "key command triggered" and remain State B:
  - `logic_edit.select_all`
  - `logic_edit.quantize`
  - `logic_navigate.zoom_to_fit`
  - `logic_navigate.create_marker`
  - `logic_transport.toggle_metronome`
  - `logic_transport.goto_position`

Evidence:
- v7/v10/v11/v14: repeated `success=true verified=False reason=readback_unavailable`
- v7: `goto_position` used dialog keystrokes with `resulting playhead not read back`.
- v17: `logic_navigate.zoom_to_fit.partial` returned State B twice, and final `logic_edit.select_all` / `logic_navigate.zoom_to_fit` also returned State B.

Why it matters:
- These commands are useful, but demos must label them as unverified unless we can observe the UI state change.

Acceptance criteria:
- Each key-command-backed command either gains a readback probe or returns State B with no success phrasing.
- `toggle_metronome` verifies via transport state.
- `create_marker` verifies via `logic://markers`.
- `zoom_to_fit` has at least an observable viewport/AX state or remains explicitly unverified.

### 9. Transport stop AX lookup fails in some real UI states

Observed behavior:
- `logic_transport.stop` sometimes failed because the Stop button could not be found in the control bar.
- The capture script had to click a hard-coded UI coordinate fallback.

Evidence:
- v10/v14: `kick.stop` -> `error=element_not_found`, hint `transport button 'Stop' not located in control bar`.
- v10/v14 scripts emitted `ui_stop_fallback`.

Why it matters:
- Stop is a core transport control and should not depend on demo-script coordinates.

Acceptance criteria:
- Stop works through a robust multi-path strategy: AX button, key command, menu command, and final transport readback.
- If already stopped, response returns unchanged State A with observed transport state.

### 9b. Transport play and record AX lookup fails in real UI states

Observed behavior:
- In v15, `logic_transport.record` failed with `element_not_found` across multiple track passes.
- Final `logic_transport.play` also failed with `element_not_found`.

Evidence:
- v15: `kick.record` -> `error=element_not_found`
- v15: `bass.record` -> `error=element_not_found`
- v15: `stab.record` -> `error=element_not_found`
- v15: `logic_transport.play final` -> `error=element_not_found`
- v15: `logic_transport.stop final` -> `error=element_not_found`
- v17: rich-techno live-record path used `ui_record.*`, `ui_stop.*`, `final.ui_play`, and `final.ui_stop` instead of product `logic_transport.*` calls because the product transport path was not reliable enough for the public demo.

Why it matters:
- Record and play are core transport operations for a real Logic demo.
- The product should not depend on coordinate-level UI scripting for these actions.

Acceptance criteria:
- `record`, `play`, and `stop` work from a fresh Logic Pro 12.2 English UI project in a normal arrange-window state.
- The implementation uses AX control lookup, key command/menu fallback, and transport-state readback.
- Hard lookup failures include scanned UI landmarks and a recovery hint.

### 10. `record_sequence` is not reliable enough to claim as a working feature

Observed behavior:
- During v7 QA, `record_sequence` produced `readback_mismatch` and was intentionally excluded from success claims.
- During v17 rich-techno capture, `record_sequence` was retried as an alternative after `import_file` failed, but 11 layers remained blocked by `readback_mismatch`.

Evidence:
- Memory entry for v7: "`record_sequence` was not included as a success feature because live testing produced `readback_mismatch`."
- 2026-06-18 v17 QA note: 11/11 `record_sequence` layer attempts failed with `readback_mismatch`; final transcript source explicitly says actual Logic recording + `logic_midi.play_sequence` was used because `record_sequence` remains covered by #42.

Why it matters:
- This is the product's most obvious "compose into Logic" API surface.
- If it cannot verify imported MIDI regions on the intended track, it should be treated as an issue.

Acceptance criteria:
- `record_sequence` creates/imports a MIDI region on the intended track and verifies it by region readback.
- Response includes target track, region name, start/end, note count, and verification source.
- Failure mode distinguishes import failure, wrong-track import, timing mismatch, and unreadable readback.

### 11. `import_file` rejects valid `/tmp/LogicProMCP/*.mid` paths after macOS normalization

Observed behavior:
- During v17, the rich-techno harness attempted to import 11 MIDI files from `/tmp/LogicProMCP/*.mid`.
- Every `logic_midi.import_file` call failed before reaching Logic.
- Response payload reported `error=channels_exhausted` with hint `midi.import_file path must be /tmp/LogicProMCP/*.mid`.

Evidence:
- v17: `import.v4_909_kick` through `import.v4_noise_transitions` -> `error=channels_exhausted`
- Example harness path: `/tmp/LogicProMCP/v17_v4_909_kick.mid`
- Root cause from code review: `MIDIDispatcher.importFilePathParam` standardizes `/tmp/...` to `/private/tmp/...` on macOS, then checks the normalized path against the literal `/tmp/LogicProMCP/` prefix.

Why it matters:
- MIDI file import is the cleanest path for precomposed multi-track material.
- This blocks real composition demos and returns a misleading channel-exhaustion error for a deterministic path validation failure.

Acceptance criteria:
- `logic_midi.import_file` accepts both `/tmp/LogicProMCP/*.mid` and the macOS-standardized `/private/tmp/LogicProMCP/*.mid` representation.
- Paths outside the allowed temp directory still fail closed.
- Path validation failures are reported separately from channel exhaustion.
- Add regression coverage for `/tmp` symlink normalization.

### 12. Instrument/patch assignment is not a verified product workflow

Observed behavior:
- Demo attempts repeatedly produced visually similar/default instrument tracks.
- v10/v11 user feedback called out that the instruments looked the same.
- v15 script moved to manual Logic Library patch clicks instead of a verified MCP patch assignment command.

Evidence:
- Memory entry: v10/v11 issue "same Deluxe Classic software instrument/patch replication."
- v15 script uses `choose_patch(...)` coordinate clicks for kick, bass, and stab patches.

Why it matters:
- A compelling music demo requires distinct roles: kick, bass, hats, stab, drummer, audio, external MIDI.
- Manual Library clicking is not a product capability.

Acceptance criteria:
- Provide a verified patch/instrument selection workflow for selected or target track.
- Response includes requested patch, observed patch/name, target track, and readback state.
- Demo can create distinct techno layers without manual coordinate patch selection.

## P2 Demo Harness / Release Credibility

### 13. Real Logic audio was not captured; guide audio was synthesized

Observed behavior:
- v10, v11, v12, v13, v16, and v17 used guide audio because no system audio capture device was available.
- Reports explicitly avoided claiming Logic system audio.

Evidence:
- Memory entries for v10/v11/v12/v13/v16/v17: "system audio capture device unavailable" and "guide audio".
- v17 final transcript source: "final audio is rendered as a guide track in post".

Why it matters:
- A public demo is stronger if it plays actual Logic output or a verified bounced export.

Acceptance criteria:
- Demo pipeline captures real Logic output or uses a verified bounce/export file.
- Post-bounce analysis confirms duration, loudness, and non-silence.
- Synthetic guide audio is not used for final public demos unless explicitly labeled.

### 14. Guide audio misrepresents visible Logic instrument state

Observed behavior:
- v17 visibly recorded MIDI into Logic, but the rendered audio was a separate multi-timbre guide track generated by the renderer.
- The visible Logic session did not verify distinct instrument or patch assignment.
- Track creation remained State B (`verified=false`, `readback_unavailable`) for 11/11 layers.

Evidence:
- v17 renderer: `render-reddit-rich-techno-ui-v17.py` writes `/tmp/logic-v17-rich-techno-guide-audio.wav` through `synth_audio()`.
- v17 transcript source: "final audio is rendered as a guide track in post".
- User review: visible Logic appeared to use one/default instrument state while the video audio contained multiple instrument timbres.

Why it matters:
- This is a demo credibility failure. The audible result must not sound richer than the verified Logic session.
- Public viewers could reasonably infer the sound came from the visible Logic project, which was not proven.

Acceptance criteria:
- Public demo renders do not pair synthetic multi-instrument guide audio with a Logic capture that only verifies MIDI entry/default instrument tracks.
- Real demos use actual Logic system audio, a verified Logic bounce/export, or verified per-track instrument state that matches the audible result.
- Demo QA checks compare visible/verified instrument state against rendered audio provenance before sharing.
- v17 is excluded from public candidate status.

### 15. Fresh Logic project bootstrap is brittle for automation

Observed behavior:
- Some capture attempts found Logic running with a document but no visible window.
- Chrome could occlude the Logic chooser.
- The capture flow had to manually hide apps, focus the chooser, and click Create/Choose by text or coordinates.

Evidence:
- Conversation status around v14: Logic had document but 0 visible windows; Chrome was in front; chooser/project creation needed manual focus handling.
- v15 script has explicit `hide_distractors()`, `focus_choose_project()`, text clicks, and coordinate patch clicks.

Why it matters:
- Demos and live E2E tests need deterministic startup from a fresh Logic state.

Acceptance criteria:
- Add a reusable fresh-session bootstrap helper for demo/live tests.
- It verifies Logic running, document visible, window focused, language expected, and empty project ready.
- It reports blocked states without continuing into a polluted session.

### 16. Video rendering pipeline had non-product failures

Observed behavior:
- Early rendered videos had non-product failures: white frames from PIL alpha composition, thumbnail flash frame, fake/reconstructed UI not accepted as real Logic UI.

Evidence:
- v6 memory: first render had white frames and was discarded; thumbnail at 42.0s hit a flash frame.
- v13 memory: visual reconstruction was explicitly not real Logic UI.

Why it matters:
- This is not a product API bug, but it affects release credibility.

Acceptance criteria:
- Demo renderer has automated black/white-frame detection, thumbnail frame validation, and a "real UI only" mode.
- Final public demo assets include an evidence manifest: source capture, transcript, ffprobe, blackframe/whiteframe scan, contact sheet, and audio provenance.

### 17. `set_cycle_range` cannot set numeric locators in real Logic UI

Observed behavior:
- During the v18 rebuild, the pipeline attempted to prepare a real Logic bounce/export range because synthetic guide audio was banned.
- `logic_transport.set_cycle_range {start: 1, end: 49}` failed in the live Logic UI.
- The response reported `channels_exhausted` and said Logic's cycle locators are not exposed as AX text fields.

Evidence:
- 2026-06-18 v18 rebuild attempt after v17 guide-audio rejection.
- Observed hint: "set_cycle_range: Logic's cycle locators aren't exposed as AX text fields in this build".
- This blocked a clean verified bounce range for an actual Logic audio export.

Why it matters:
- Verified bounce/export workflows need a reliable range.
- Without a verified cycle/locator setter, demos can accidentally bounce one bar or a selected fragment.

Acceptance criteria:
- `set_cycle_range` can set numeric locators in Logic Pro 12.2 real UI or returns a specific unsupported state.
- The command verifies observed start/end after setting.
- Bounce/export workflows fail closed if they cannot establish the requested range.

### 18. Reusing polluted Logic sessions hides fresh-project truth

Observed behavior:
- v18 removed guide audio but reused the v17 raw capture, so the visual session still had stale/high track numbering and uncertain instrument state.
- v20 used Logic's own Create New Track dialog to create four tracks; the baseline screenshot showed 1, 2, 3, and 4, but the final screenshot regressed to 1, 18, 19, and 20.

Evidence:
- v18: `docs/media/reddit-dudddee-rich-techno-ui-v18-truthful.mp4`
- v20 baseline: `/tmp/logic-v20-fresh-4tracks-baseline.png`
- v20 final: `/tmp/logic-v20-fresh-final.png`
- v20 transcript: `docs/media/reddit-dudddee-fresh-truthful-ui-v20-transcript.json`
- v22 mitigation: `docs/media/reddit-dudddee-fresh-truthful-ui-v22-transcript.json`

Why it matters:
- A from-scratch public demo needs a process-level fresh Logic session, not only a visually empty arrange window.

Acceptance criteria:
- Demo/live harnesses verify a clean Logic process and visible track numbering before capture.
- A from-scratch demo fails QA if track numbering jumps to stale/high values.
- Rejected polluted captures are not reused as final demo sources.

### 19. `create_instrument` timeout can pollute fresh capture track numbering

Observed behavior:
- During v19, the baseline screenshot showed a fresh track 1.
- `track2.create_instrument`, `track3.create_instrument`, and `track4.create_instrument` timed out.
- The final screenshot showed a visible track 18 and a Free Tempo Recording modal.

Evidence:
- v19 baseline: `/tmp/logic-v19-fresh-track1-baseline.png`
- v19 final: `/tmp/logic-v19-fresh-final.png`
- v19 transcript: `docs/media/reddit-dudddee-fresh-truthful-ui-v19-transcript.json`

Why it matters:
- Track creation timeout is not a harmless failure if it mutates or pollutes the visible project.

Acceptance criteria:
- `logic_tracks.create_instrument` either returns a verified new track or fails closed without mutating the project.
- Timeout is treated as a hard abort by demo harnesses.
- Modal interruptions are surfaced as blocked UI states instead of continuing capture.

### 20. Track arm/arm_only reports success while record-enable readback is unavailable

Observed behavior:
- During v27, all five `logic_tracks.arm_only` calls were classified as transcript `state=ok`.
- Each response embedded an inner `recArm` detail with `success=true`, `verified=false`, and `reason=readback_unavailable`.

Evidence:
- v27: `distorted_kick_rumble.arm_only` track 0 -> nested `verified=false`
- v27: `rolling_sub_bass.arm_only` track 1 -> nested `verified=false`
- v27: `metallic_hats.arm_only` track 2 -> nested `verified=false`
- v27: `minor_stabs.arm_only` track 3 -> nested `verified=false`
- v27: `acid_screech_lead.arm_only` track 4 -> nested `verified=false`

Why it matters:
- Record-arm is a mutating track operation. The caller needs to know that the intended track is actually armed before recording MIDI into Logic.
- Transcript classification must not collapse nested unverified results into an outer ok event.

Acceptance criteria:
- `logic_tracks.arm` and `logic_tracks.arm_only` return State A only after observed record-enable state matches the requested target track.
- If readback is unavailable, the outer operation reports State B or a structured unverified result instead of plain success.
- `arm_only` verifies that other tracks were disarmed or reports partial/unverified status.

### 21. Transport state readback can remain stale after visible Stop and MCP stop

Resolution status:
- The cycle/readback half of this class is covered by issue #59 / PR #54, which aligned `logic://transport/state` with the verified Logic 12 control-bar readback path for cycle state.
- Stop/play/record readback hardening remains tracked by #56 unless each transport command now gates State A on fresh observed `isPlaying/isRecording` values.

Observed behavior:
- Later transcripts showed `logic://transport/state` reporting playing or recording after visible Stop events and, in v25, after a product `stop` call.

Evidence:
- v24: after `final.ui_stop`, `logic://transport/state.after` reported `isPlaying=true` and `isRecording=true`.
- v25: after `final.ui_stop`, `final.mcp_stop`, and `final.goto_bar_1.after_stop`, final transport readback still reported `isPlaying=true` at position `96.1.1.1`.
- v27: after `final.ui_stop`, final transport readback reported `isPlaying=true` and `isRecording=true`.

Why it matters:
- Transport readback is the verification gate for stop/play/record behavior.
- Stale readback can make the harness continue after a failed stop or misreport the current recording state.

Acceptance criteria:
- `logic://transport/state` refreshes from live Logic state after transport actions instead of returning stale cached state.
- `logic_transport.stop` verifies observed `isPlaying=false` and `isRecording=false` before returning State A.
- If Logic state cannot be refreshed, the response marks the result as stale or unverified with cache age and recovery hint.

### 22. Unverified go-to-beginning can let live MIDI record at stale high bar positions

Observed behavior:
- v23 and v25 sent live MIDI after `goto_bar_1` operations that returned `success=true`, `verified=false`, and `reason=readback_unavailable`.
- v25 was rejected as an actual Logic UI final because transport/playhead position did not reliably return to bar 1 and visible regions were pushed later in the arrangement.

Evidence:
- v23: four `goto_bar_1` operations returned State B before live MIDI passes.
- v25: five per-instrument `goto_bar_1` operations and two final `goto_bar_1` attempts returned State B.
- v25 final transport readback ended at position `96.1.1.1`.

Why it matters:
- A composition workflow can create the right notes at the wrong bar if playhead reset is not verified.
- A public from-scratch demo must fail closed when the requested record position is not proven.

Acceptance criteria:
- Any live-record demo step that requires bar 1 verifies the observed playhead position before sending MIDI.
- `goto_bar` / `goto_position` returns State A only with observed matching position; otherwise State B/C stops the demo harness.
- If the playhead is not at the requested bar, subsequent MIDI send/record actions are skipped and the capture is marked blocked.

### 23. Free Tempo Recording modal can interrupt fresh live-record captures

Observed behavior:
- v19 and v20 ended with a visible Logic Free Tempo Recording modal during fresh capture attempts.
- v22 required repeated modal dismissal attempts before each track and before final verification.

Evidence:
- v19 final screenshot: `/tmp/logic-v19-fresh-final.png`
- v20 final screenshot: `/tmp/logic-v20-fresh-final.png`
- v22 transcript: `track1_drums.free_tempo_modal`, `track2_bass.free_tempo_modal`, `track3_acid.free_tempo_modal`, `track4_stab.free_tempo_modal`, and `final.free_tempo_modal` were all attempted modal guards.

Why it matters:
- Modal interruption changes the UI state underneath transport, recording, and region verification.
- Continuing while the modal is present can produce polluted or occluded captures.

Acceptance criteria:
- Demo/live harnesses detect the Free Tempo Recording modal before continuing with transport, MIDI, or screenshot verification.
- The product or harness either dismisses the modal through a deterministic, named action or fails closed with a clear blocked state.
- Final QA checks reject captures where the modal is still visible.
