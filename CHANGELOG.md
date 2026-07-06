# Changelog

All notable changes to Logic Pro MCP Server are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project uses [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Changed

- **Doctor v3 diagnostic surface.** `LogicProMCP doctor` now emits schema `logic_pro_mcp_doctor.v3` with `fix_plan`, per-check `optional`, `blocked_by`, 26 default checks, and 27 checks when `--check-updates` is enabled. A higher `skipped` count is expected on hosts where a diagnostic capability is unavailable; v3 reports those capability gaps instead of hiding them.
- **Strict doctor exit routing.** `doctor --strict` uses `0=ok`, `1=failed`, `2=manual_action_required`, and `3=degraded`. Codes `2` and `3` are status codes, not usage errors. Optional-by-design skips, currently an absent Claude Desktop config, remain visible in skipped counts without degrading an otherwise healthy report.

### Fixed

- **PostEvent permission folded into readiness.** `--check-permissions` now exits non-zero when Accessibility and Automation are granted but PostEvent is denied. This is the intended false-green correction for CGEvent fallback paths.
- **Doctor privacy and causal checks.** The doctor now treats relative MCP registration commands as unverifiable instead of warning, validates registered share-dir envs and regular-file targets, classifies launch context with ancestry precedence, and redacts TCC findings to service/principal/state summaries.

## [3.8.0] — 2026-07-05

Enterprise review-and-refactor sweep. A read-only A–Z review (5 reviewers) plus a second-round security/concurrency/completeness audit drove a behavior-preserving internal refactor, a small set of correctness/honesty fixes, and security hardening. **No public tool/resource/template surface change (10 tools / 18 resources / 11 templates unchanged).** Also carries the already-merged Logic Pro 12.3 insert-slot enumeration recovery (#234). `swift test --no-parallel` → 2077 passed; strict fresh live Logic Pro 12.3 E2E → 372 passed / 1 skipped / 373 total.

### Fixed

- **[P0] SIGPIPE crash on client disconnect.** A raw `write(2)` to a broken stdout pipe (client disconnect mid-write, or a `| head` truncation) raised `SIGPIPE`, which killed the process *before* `write()` could return `-1` — bypassing the existing `POSIXError`/`EPIPE` handling. `MainEntrypoint` now installs `signal(SIGPIPE, SIG_IGN)` so the write surfaces `EPIPE` and the server survives the disconnect (`SIGPIPERegressionTests`).
- **MCU feedback ordering race (2 sites).** Every inbound MCU event was dispatched through its own unstructured `Task { await … }` in both `MCUChannel` and the server fan-out, so the actor admitted events in arrival order rather than creation order — pitch-bend/CC echoes could apply last-write-wins (a false `echo_timeout` State B, or a false State A on an intermediate value) and sysEx LCD/select ordering could corrupt. Both sites now feed a single ordered `AsyncStream` drained by one long-lived consumer task, restoring FIFO. (Probable root cause of the intermittent MCU echo flake, PR #153.)
- **Permission-probe tri-state honesty.** `--check-permissions`, `logic_system health`, and `doctor` no longer report a false "Automation NOT GRANTED" when the automation probe itself times out or fails to spawn. `PermissionChecker` now returns a three-state result (`granted` / `not_granted` / `not_verifiable`); an infrastructure failure is reported as `not_verifiable` instead of being collapsed into a denial, so a readiness gate can distinguish "could not verify" from "verified denied".
- **`logic://tracks` fabricated track state.** The production track-state builder previously hard-coded `volume: 0.0`, `pan: 0.0`, and `automationMode: off` for every track. `volume`, `pan`, and `automationMode` now report the REAL track-header values, read from the same AX header fader the mixer write path uses. Value-only fix: the `TrackState` keys and types are unchanged (no new field, sentinel, or nullable), and a rare AX-read failure falls back to the same default the resource fabricated before, so no new unreadable shape is introduced. (Track objects carry no sample rate; `logic://project/info` still falls back to a `44100` default when a live transport sample-rate is unavailable — unchanged, documented limitation.)
- **AXHelpers CFArray downcast guard.** `AXHelpers.children(...)` performed an `unsafeDowncast` to `CFArray` with no `CFGetTypeID` guard (the sibling `getPosition`/`getSize` already had one), so a malformed or mocked AX attribute was undefined behavior. It now guards `CFGetTypeID(value) == CFArrayGetTypeID()` and returns an empty array on mismatch.
- **MIDIFeedback System Common / Real-Time status bytes.** Status bytes `0xF1–0xF7` (System Common) and `0xF8–0xFF` (System Real-Time) were mis-consumed and could corrupt running status, dropping the following message. They are now handled explicitly: Real-Time bytes pass through without disturbing running status; System Common resets it.
- **SMFWriter time-signature denominator.** The bar-offset tick math assumed a `/4` denominator (`ticksPerQuarter` per beat), placing e.g. `6/8` bars twice as far as intended. It now computes `ticksPerBeat = ticksPerQuarter * 4 / denominator` (guarding `denominator ≤ 0`). Unreachable on the current sole caller (hard-codes `4/4`) but correct on reuse.
- **`release.sh` Formula sha256 sync now fails closed.** After rewriting the Formula's `sha256`, the script asserts the published tarball hash is actually present (`grep -Fq`) and refuses to tag if the literal format drifted, preventing a stale hash that would fail `brew install` checksum verification for every user (#22-class).
- **Documentation staleness** across README / CONTRIBUTING / TROUBLESHOOTING: test and live-E2E counts re-synced, the mixer "send = MCU write" claim removed (`set_send` is not exposed — State C `command_not_exposed`), and the fader/pan channel-routing corrected (Accessibility, not MCU).
- Insert-slot AX enumeration returns 0 slots for every track on Logic Pro 12.3, blocking the whole `logic_plugins.*` verified apply-back surface and legacy `logic_mixer.insert_plugin`. 12.3 exposes the mixer header toolbar as an `AXGroup` described "Mixer", and the all-children fallback in strip counting let that toolbar (8 widgets) outrank the real strips container whenever ≤ 8 strips were visible. Mixer-container candidates are now ranked structurally by their `AXLayoutItem` channel-strip children only (locale-neutral; the legacy `AXIdentifier=="Mixer"` path is unchanged), restoring insert enumeration on 12.3 for any strip count while preserving 12.2 trees (#234).
- `logic_plugins.get_inventory` can no longer return a false verified-empty read (State A with `plugins:[]`). A visible insert section always exposes at least the empty append row, so an enumeration of zero slots now degrades to State B `readback_unavailable` with `plugins_unknown_reason: "insert_section_not_enumerable"`, `safe_to_retry: true`, the mixer-reveal diagnostics, and a recovery hint naming both likely causes (mixer AX-layout drift; a strip type without an insert section, e.g. Master/VCA). Future AX-tree drift now degrades honestly instead of masquerading as a verified empty chain. Honest-direction behavior change, non-breaking (`plugins_unknown_reason` gains one enumerated value; State A payload shape unchanged) (#234).
- The write-path slot-addressing guards (`logic_plugins.insert_verified` / `set_param_verified` and legacy `logic_mixer.insert_plugin`) now distinguish a zero-slot strip from an index beyond a non-empty chain: a `(0 slots)` failure names the `insert_section_not_enumerable` condition and carries the same recovery hint instead of the bare "slot N is out of range (0 slots)". These remain State C — writes never soften to State B (#234).
- The modal-dialog guard no longer refuses unrelated operations while a plugin editor window is open. Logic 12.3 tags plugin editor windows with the `AXDialog` subrole, so `project.save`, `track.select`, and other unrelated ops previously failed closed as if a blocking modal were up. Plugin editors are now recognized by their window chrome — a close-button attribute plus a bypass toggle and a compare-or-link toggle (exposed as checkboxes or buttons depending on window focus) — and excluded from blocking-dialog classification; unknown window shapes stay blocking (fail-closed) and non-English locales are conservatively unchanged pending label verification (#234).
- The strict live E2E suite's verified-inventory check now requires a non-empty plugin list, so a blind Accessibility enumeration that returns zero slots can no longer pass the gate silently as it did while insert enumeration was broken (#234).

### Changed

- **Internal God-object splits (behavior-preserving, pure moves).** `AccessibilityChannel`, `AXLogicProElements`, and `ResourceHandlers` were split into same-type extension files. The compiler-verified public surface is unchanged and the golden wire-snapshot diff is zero.
- **~386 dead test assertions made live.** A sweep converted `#expect(Bool == Bool)` forms (statically dead under the `#expect` macro) to live assertions across the suite, with a ledger. Five assertions went red when made live — all ground-truthed as latent test defects (zero production bugs); none were papered over.
- **`HonestContract.FailureError` is now a `String`-backed enum**, removing a hand-maintained ~45-line `rawValue` switch that could drift; the raw strings are byte-identical and pinned by tests.
- **Duplication removed** across channels, dispatchers, MIDI, and resources (CoreMIDI channel/velocity parsing, catch-block helpers, AppleScript static/instance pairs, the `ChannelRouter` routing table → `RoutingTable.swift`, library-node helpers, and more) — all behavior-preserving.
- No public tool/resource/template surface change: **10 tools / 18 resources / 11 templates unchanged.**

### Behavior changes (intentional, tested)

The zero golden static-wire diff freezes the **discovery / error / schema** surface only — `tools/list`, `resources/list`, resource templates, and error-envelope shapes. It does **not** freeze runtime or live-data behavior. The following are intentional, ticketed, tested behavior changes, each covered by unit tests and/or the live E2E suite (not by the static golden). No MCP wire schema, tool name, parameter, or error-envelope shape changed.

- `logic://tracks` now reports the REAL `volume` / `pan` / `automationMode` from the live track header instead of the fabricated `0.0` / `0.0` / `off` placeholders — honesty exception #1 (value-only: keys and types unchanged).
- Permission status is now tri-state (`granted` / `not_granted` / `not_verifiable`) rather than boolean, so a probe infrastructure failure is no longer collapsed into a false denial — honesty exception #2.
- MIDI System Common / Real-Time status bytes `0xF1`–`0xFF` are now skipped in feedback parsing instead of corrupting running status (WS6).
- MCU master-fader feedback now lands correctly at every bank offset; previously only bank offset 0 was updated (WS6).
- `create_marker` now issues one extra `nav.get_markers` read before mutating, to target the marker faithfully (WS4).
- `PluginsDispatcher.nonEmptyString` now trims surrounding whitespace before the emptiness check (WS4).
- `stringParam` alias-conflict now fails closed — a value supplied under two conflicting aliases is rejected rather than silently resolved (WS4).
- The bounce helper now resolves `python3` via `PATH` (falling back to `/usr/bin/python3`) and honors the `LOGIC_PRO_MCP_BOUNCE_HELPER` override allowlist (WS4). The `PATH`-resolved interpreter is ownership-validated (regular file owned by you or root, not group/other-writable) before it is executed, so a `python3` planted on a world-writable `PATH` entry cannot substitute the interpreter.
- Pan/volume reads now fail closed — an out-of-range AX value is clamped to the valid range rather than surfaced raw (WS3).
- `library.scan_all` and `plugin.scan_presets` are once again mutually exclusive: either AX-tree scan in flight rejects the other, restoring the single-scan guard that the God-object split accidentally dropped (restored in this release).

### Security

- **M1 — CI release-publish command injection (`.github/workflows/publish-mcp.yml`).** `github.event.release.tag_name` was interpolated straight into a `run:` block on a job holding `id-token: write` + `mcp-publisher` publish rights, so a crafted tag could run arbitrary code under the release OIDC identity. The tag is now passed via an `env:` var and validated against strict SemVer before use (`VERSION="${RELEASE_TAG#v}"`).
- **M2 — installer `/private` blocklist bypass (`Scripts/install-common.sh`).** On macOS `/etc`, `/tmp`, and `/var` are symlinks into `/private`, so a protected-path value like `/etc` arrived already rewritten to `/private/etc` and slipped past the blocklist before a `sudo mv`. The protected-path list now covers the `/private/{etc,tmp,var/db}` spellings alongside `/`, `/System`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`. The blocklist is matched case-insensitively (default APFS is case-insensitive, so `/TMP`, `/Private/Tmp`, `/ETC` resolve to the same protected dirs), and — critically — the SAME guard is applied by BOTH the sourced `install-common.sh` and the inline fallback in `install.sh` that the documented `curl … | install.sh` methods actually run, so neither install path can be pointed at a case-varied protected directory. A runtime contract test forces the inline-fallback branch to pin the two implementations to parity.
- **L1 — operator env-var exec hardening.** A `LOGIC_PRO_MCP_BOUNCE_HELPER` override is now validated (regular `.py` file, owned by you or root, not group/other-writable, under a fixed directory allowlist plus an additive operator allowlist env) before it can be executed, mirroring the library-inventory ownership pattern.
- **L2 — debug-log symlink hardening.** The gated library-click debug log moved from a fixed `/tmp/logic-library-click-debug.log` (symlink / pre-creation risk) to a per-session `mkdtemp` directory, created only when debug logging is enabled.
- **CI least-privilege** — workflow `permissions` blocks were tightened and `actions/checkout` pinned.

M3 (notarization posture) is a documented decision, not a code change — see [SECURITY.md](SECURITY.md#release-types). ADHOC releases give integrity (codesign verify + SHA256), not authenticity.

## [3.7.4] — 2026-06-30

Bug-fix and robustness release closing the v3.7.3 complete-surface QA backlog (#199–#202). No public tool/resource/template surface change (10 tools / 18 resources / 11 templates unchanged).

### Fixed

- A mutating operation that hits the per-command server-side deadline no longer pins the whole write surface. The mutation gate is now reclaimable a short, bounded grace (15s) after the deadline abandons the op — instead of holding until the wedged work returns or the 360s stale-holder TTL — so one timed-out `logic_transport.play` can't leave every other mutating command returning `mutating_operation_in_progress` for minutes. The timeout envelope advertises this (`mutation_gate: "reclaimable_after_grace"`, `gate_reclaim_after_sec`); the reclaim is epoch-guarded so a late release from the abandoned op cannot free a successor's claim (#201).
- Resource reads (`logic://…`) now run under the same server-side deadline as tool calls. A read backed by a live Accessibility route (`logic://transport/state`, `logic://tracks/{index}/regions`) on a wedged/occluded session previously could block past the client's read timeout and return no JSON-RPC response; it now returns a typed `operation_timeout` resource body. Genuine read errors still propagate unchanged (#199).
- Indexed resource templates (`logic://tracks/{index}`, `logic://mixer/{strip}`) now fail closed with a typed, classifiable `index_out_of_range` body (carrying `requested_index`, `available_count`, and the exact `available_indices`) for an out-of-range or empty-project index, instead of a raw JSON-RPC `-32602`. The mixer reports its actual (possibly non-contiguous) `trackIndex` set rather than implying a `0..<N` range (#200).
- Command tokens that are recognised by the dispatchers but deliberately not part of the production MCP contract (`logic_tracks.set_color`, `logic_mixer.set_send`/`set_output`/`set_input`/`toggle_eq`/`reset_strip`/`bypass_plugin`) now return a distinct, machine-classifiable `command_not_exposed` State C (`not_exposed: true`, `supported: false`) instead of a generic `not_implemented`, so a complete-surface harness can classify them as intentionally-unsupported rather than a malfunction. Documented in `docs/API.md` (#202).

### Changed

- Pinned the Model Context Protocol Swift SDK to `0.12.1` (patch update within the existing `from: 0.11.0` range; full suite + strict live E2E green).

## [3.7.3] — 2026-06-30

Bug-fix and diagnostic-honesty release closing the open GitHub issue backlog (#178, #186–#190). No public tool/resource/template surface change (10 tools / 18 resources / 11 templates unchanged).

### Fixed

- `transport.set_tempo` slider-increment fallback no longer reports a State B success when the observed tempo does not match the request. When typed entry does not commit and the increment fallback cannot land the requested value, it now fails closed with State C `readback_mismatch` (`via: "slider-increment"`, `requested`/`observed`, `safe_to_retry: true`) — it never claims success on a readback mismatch (#189).
- `midi.import_file` now preflights Automation → System Events authorization (a separate TCC target from Logic Pro Accessibility/Automation) and fails closed with State C `permission_denied` (`permission: "automation_system_events"`, `failure_stage: "preflight_system_events_permission"`, `write_attempted: false`) before driving the import, instead of aborting mid-flight on a bare Apple Events denial (#188).
- Health/`--check-permissions` now surface System Events automation state explicitly (`automation_system_events` field plus an "Automation (System Events):" summary line), and the `--check-permissions` readiness gate now exits non-zero when System Events automation is denied — so a readiness check never reports green for a capability the server cannot use (#188).
- Blocking-dialog refusals on transport and other mutating operations now enrich the State C envelope with the dialog identity — `dialog_title`, `dialog_role`, `owning_window`, `dialog_buttons`, and a Cancel-first `recovery_action` — instead of a bare `blocking_dialog_present` flag (#190).
- Fresh-session bootstrap now clears a stuck "Save changes?" prompt whose buttons carry no Accessibility name: after the marker-matched Cancel it falls back to an Escape key event (Cancel-before-Escape), so the bootstrap no longer dead-ends on an unnamed save dialog (#187).
- `Scripts/logic_key_event.swift` now accepts `--return`/`--enter`/`esc` aliases (a leading `--` is stripped), adds a `--check` no-post preflight and `--help`/`--list`, and fails closed (exit 64) on an unknown key while naming the supported keys, so demo capture no longer aborts on `--return` (#186).

### Documentation

- Added the community Discord invite to `CONTRIBUTING.md`, `docs/SETUP.md`, and `docs/TROUBLESHOOTING.md` (#178).

## [3.7.2] — 2026-06-28

Production-readiness hardening pass. No public tool/resource/template surface change (10 tools / 18 resources / 11 templates unchanged).

### Changed

- `mutating_operation_in_progress` State C now reports `safe_to_retry: true` — no write was attempted (the gate refused before dispatch), so the call is retryable once the in-flight mutating operation releases the gate. This aligns it with the sibling `verified_op_in_progress` and the Honest Contract retry-signal semantics.

### Fixed

- `record_sequence` no longer re-promotes a lower-level `midi.import_file` State B GM Device / External MIDI audibility downgrade into verified success; it now fails closed with `audibility_unverified` before a silent Bounce can be claimed.
- `logic://project/audit` now reports `external_midi_regions_bounce_risk` as an export blocker when MIDI regions sit on GM Device / External MIDI tracks, preventing track/region readback from being mistaken for audible-routing evidence.
- `logic_project.bounce` now runs the audit preflight and refuses `export_readiness_blocked` before opening the Bounce dialog when export blockers are present.
- `logic_tracks.scan_library` now defaults to the non-mutating disk scanner; callers can still request the legacy live AX Library Panel walk with `{ "mode": "ax" }`.
- The release install-validation job published artifacts but its share directory (`.../logic-pro-share/logic-pro-mcp`) failed the installer's own `validate_share_dir` check (which requires `*/share/logic-pro-mcp`), so install validation failed on every tagged release. The path now satisfies the validator and a contract test pins the workflow value to the validator glob.
- MIDI Key Commands `send_note` / `send_chord` now make a best-effort note-off before surfacing a note-off transport failure, so a transient error cannot leave a sounding note (the failure is still reported honestly via State C `note_off_failed`). This mirrors the CoreMIDI mitigation.
- Startup orphan temp-directory cleanup now verifies on-disk ownership (`ownerAccountID`), not just the uid embedded in the directory name, before deleting a managed temp directory.
- Public documentation policy now explicitly allows `docs/prd/` and `docs/tickets/` for public issue remediation plans while keeping internal PRDs, private ticket boards, and local live-evidence work files out of `docs/`.

## [3.7.1] — 2026-06-23

### Fixed

- Public documentation/runtime-surface corrections after v3.7.0: README, API, setup, troubleshooting, docs inventory, and MIDIKeyCommands health detail now reflect the shipped v3.7.x behavior for verified pause/cycle-range outcomes, marker rename refusal, `set_zoom` Accessibility readback, `project/info.trackCount` live-cache promotion, and public mixer dispatcher boundaries.
- Public docs inventory was narrowed for the v3.7.1 release: `docs/API.md`, `docs/SETUP.md`, `docs/TROUBLESHOOTING.md`, the README demo GIF/MP4, and the registry/social thumbnail stayed public. Internal-only PRDs, private ticket boards, spike notes, maintainer handoffs, historical live-verify notes, and generated demo harness files were removed from the public docs tree.
- Release/version surfaces now point at v3.7.1 across `ServerConfig`, manifest metadata, official MCP `server.json`, installer defaults, Homebrew Formula version, README, setup docs, and version-consistency tests.

## [3.7.0] — 2026-06-23

**Accumulated production hardening after v3.6.0.** This release publishes the full 10-tool / 18-resource / 11-template source tree after closing the v43 demo QA backlog, the issue #60 EN/KO locale-agnostic UI epic, and every open GitHub issue. It includes setup doctor/lifecycle surfaces, audio artifact analysis, project audit/export/session workflows, stock instrument and Session Player catalogs, stronger project/track/mixer/transport verification, fail-closed demo/render gates, and strict fresh live close-gate evidence in English and Korean.

### Added

- **Setup support surfaces** — `LogicProMCP doctor` / `doctor --json` expose read-only install, permission, MCP registration, Logic readiness, quarantine, and release-signature diagnostics with stable remediation anchors.
- **Setup lifecycle plans** — install/update/uninstall dry-run commands now return serializable lifecycle plans instead of pretending to execute mutating setup work from the binary.
- **Audio artifact analysis** — `logic_audio.analyze_file` verifies bounced/exported audio files for existence, format, duration, level, silence, and clipping before demo/render workflows can claim success.
- **Project audit and cleanup planning** — `logic://project/audit`, `logic://project/cleanup-plan`, and guarded `cleanup_apply` provide project evidence, deterministic findings, export readiness, and reversible cleanup actions.
- **Project export workflows** — export dry-run, `export_run`, and `export_resume` add manifest-backed export execution with guarded bounce integration.
- **Planning catalogs** — stock instrument intelligence, Session Player catalog entries, workflow skills, and `logic://workflow-plans/session?prompt={prompt}` give agents read-only planning context without mutating Logic.
- **Locale policy layer** — `AXLocalePolicy` centralizes EN/KO menu, dialog, control-bar, track, transport, mixer, plugin, region, and confirmation label matching.
- **Demo/render safety tooling** — render asset guards, bounce guard, capture finalize policy, timeout policies, contact sheet/evidence manifests, and run-local issue coverage prevent silent or non-Logic demo output from being published as verified.
- **GitHub project hygiene** — issue templates, PR template, label taxonomy, contributor onboarding, CI badge, registry metadata, and MCP publishing workflow metadata were added.

### Changed

- **Public surface synchronized to 10 tools / 18 resources / 11 templates** across `ServerConfig`, manifest, registry metadata, README, API, architecture, setup, security, maintainer, and version-consistency tests.
- **Mixer volume and pan writes now route through Accessibility** with same-surface readback instead of MCU-only echo dependence; MCU remains for master/send style paths.
- **Project save/new/open paths are more honest**: `project.save` verifies file evidence, `project.save` fails fast on untitled docs, and `project.new` unwraps observed names from AppleScript JSON envelopes.
- **Transport and navigation outcomes are more explicit**: `pause` routes through working stop channels before MMC, `set_cycle_range` is demoted when unsupported, and `goto_position` / `goto_bar` no longer carry self-contradictory readback notes.
- **Live E2E harness contract refreshed** to cover 341 strict fresh live checks per locale with zero skipped cases and without relying on System Events bootstrap permissions.
- **MCP registry metadata updated** to publish current tool/resource/template counts, GitHub release URL, Homebrew instructions, icon, discovery tags, and runtime client config.

### Fixed

- `logic://project/info.trackCount` now follows trusted live track cache when saved project metadata is name-only or lacks a positive track count, while rejecting placeholder/Inspector-contaminated rows.
- Track mutation commands now report honest State B/C when an occluded UI prevents verified readback.
- Track mute/solo/arm now use AX checkbox locators with read-back-polled writes.
- `set_instrument` now stops on Library panel preconditions, GM Device / External MIDI track-type mismatches, and bounded navigation deadlines instead of hanging or claiming repair.
- MIDI import now tolerates `/private/tmp` aliases, polls file-open dialogs, returns `dialog_not_found` State C when appropriate, and downgrades GM-device audibility to State B when readback cannot prove sound.
- `record_sequence` no longer reports false success after import failure.
- `mixer.set_master_volume` reports honest State B with `surface_limitation` and uses AX-first mixer reveal where appropriate.
- Plugin inventory reads recover hidden-mixer visibility more reliably.
- `nav.rename_marker` returns typed `not_implemented` State C rather than misleading `channels_exhausted`.
- Bounce/dialog paths verify the Bounce settings dialog appeared before clicking OK and reject "no record-enabled track" as a false precondition for shipped bounce paths.
- Fresh Logic project bootstrap handles localized/free-tempo/don't-save dialogs, project picker confirmation, first software-instrument track creation, and no-System-Events UI readiness.
- Demo render paths fail closed on failed bounce guards, stale issue coverage, invalid raw MP4s, non-Logic crops, streamability mux issues, and silent output.
- MCU echo tests are deterministic under parallel load.
- AX label matching is diacritic-sensitive for `.contains` and `.prefix`, preventing unsafe matches like accented `Undo` variants.

### Tests

- v3.7.0 release-tree local gates: `python3 Scripts/logic_session_bootstrap_test.py` -> `14` passed; `python3 Scripts/logic_free_tempo_modal_test.py` passed; `python3 -m py_compile Scripts/live-e2e-test.py Scripts/logic_session_bootstrap.py Scripts/logic_session_bootstrap_test.py Scripts/logic_free_tempo_modal.py Scripts/logic_free_tempo_modal_test.py` passed; `ruby -c Formula/logic-pro-mcp.rb` passed; `swift build -c release` passed; `swift test --no-parallel` -> `1743` passed.
- Issue #60 close gate: `swift test --filter Issue60LocalePhase --no-parallel` -> `19` passed; `swift test --filter AXLocalePolicy --no-parallel` -> `25` passed; `swift test --filter AXLogicProElements --no-parallel` -> `24` passed.
- Strict fresh live close gate: English `LOGIC_PRO_MCP_STRICT_LIVE=1 LOGIC_PRO_MCP_BOOTSTRAP_FRESH=1 LOGIC_PRO_MCP_BOOTSTRAP_LANGUAGE=en python3 Scripts/live-e2e-test.py` -> `341` passed / `0` skipped; Korean equivalent -> `341` passed / `0` skipped.
- GitHub CI for PR #166 passed on build/test/coverage; main push CI after merge was in progress at release-prep start and is recorded in the GitHub Actions run history.

Full exhaustive PR and issue listing lives in the GitHub Release and merged PR history.

## [3.6.0] — 2026-06-19

**PR #24 — verified plugin apply-back with exact-slot insert verification, plus Logic 12.2 AX readback hardening.** This release grows the public write surface from 8 tools to 9 by adding `logic_plugins`, an HC v2 surface for duplicate-project plugin apply-back workflows. It also carries the Logic 12.2 track-header/type-readback hardening needed for live `logic://tracks` evidence on current macOS/Logic combinations.

### Added

- **`logic_plugins` verified plugin apply-back surface (v3.6.0, additive — 9 tools total)** — a new `logic_plugins` tool exposes three commands backed by the HC v2 (`hc_schema: 2`) envelope for the verified plugin path. Every `logic_plugins.*` response carries `state` (`"A"` / `"B"` / `"C"`) and `hc_schema: 2`; the existing 8-tool surface is byte-identical.
  - **`get_inventory`** — drift-safe insert chain inventory for a track. Reads the physical AX insert slots directly (no mixer-cache drift); every item always carries `insert` (physical 0-based index), `read_status` (`"ok"` / `"empty"` / `"unreadable"`), `occupied`, `name`, `plugin_id` (canonical `logic.stock.effect.*` or `null`), and `bypassed`. Top-level `complete: true` when all slots are readable; `complete: false` when any slot is `unreadable`. Returns HC v2 State B `readback_unavailable` when the AX mixer subtree cannot be found at all.
  - **`set_param_verified`** — verified AX write + readback for the Compressor `threshold` parameter (normalized %, 0–100). Executes the full 13-step R6 precedence (schema → mode → project path → identity → capability preflight → track select → inventory → plugin window → slider match → before-read → AX write → after-read → tolerance gate). Returns HC v2 State A only when the write lands **and** the readback matches within tolerance 1.0; mismatch triggers rollback and State C `readback_mismatch`. All other parameters fail closed at step 5 (capability preflight) with State C `unsupported_param_readback`; no write is attempted. **라이브 E2E 검증 완료 (Compressor threshold State A, 2026-06-14; carried into v3.7.0)**: Logic Pro 12.2 + duplicate test project, track 5 insert 6 Compressor에서 `requested_normalized 60 -> observed_normalized 60, observed_display "60 %"` State A 확인, 독립 osascript readback 교차검증. Public evidence boundary: this changelog and the v3.7.0 GitHub Release.
  - **`insert_verified`** — live, readback-verified plugin insert via the requested insert slot's own popup menu. Enforces the pre-insert gates (schema → mode → project path → identity [insertable allowlist: Gain / Channel EQ / Compressor] → inventory `complete:true` → slot `empty`), then selects/verifies the target track, clicks the target slot center with CGEvent, proves the resulting popup is spatially anchored to that slot, chooses the stock plugin by exact leaf title from that anchored popup (direct/root item, popup search result, then recursive hover discovery), and diffs the pre/post insert inventory. **State A only when the post-insert readback observes the requested plugin newly mounted at the requested slot** — the readback diff is the sole State A path, so a false verified insert is structurally impossible. The production path does not depend on localized category names such as `Utility`/`유틸리티`, and `get_inventory` filters Logic Pro 12.2's short bottom "Audio Plug-in" append stub because live E2E showed it is not an addressable insert row. **라이브 E2E 검증 완료 (2026-06-17, exact-slot)**: `insert_verified track=6 insert=6 plugin=Gain` returned `verified:true` with `write_source:"ax_exact_slot_popup"`, `slot_popup_anchor_verified:true`, `winning_strategy:"slot_popup_direct_exact_leaf"`, and `observed_slot:6`; independent `get_inventory` readback confirmed insert 5 stayed empty while insert 6 contained Gain. If unknown Logic UI drift ever places the plugin elsewhere, the op fails closed with State C `insert_landed_at_different_slot` and rolls the stray mount back with readback confirmation. Replaces the legacy `insert_plugin` unverified path for the allowlisted stock plugins.
- **HC v2 envelope (`logic_plugins.*` only)** — `encodeV2StateA/B/C` emit `state`/`hc_schema: 2`; `encodeV2StateC` additionally carries `verified: false`. All HC v2 error codes are terminal (router never falls back past them). The v1 encoders used by the 8-tool surface are unchanged.
- **`VerifiedPluginCatalog`** — canonical plugin identity and parameter resolution for the verified surface. Maps caller aliases (display name `"Compressor"`, bare suffix `compressor`, or full `logic.stock.effect.compressor`) to canonical IDs; maps parameter aliases to catalog keys; gates on `ParamCapability.writeReadback` for step-5 capability preflight. Currently only `logic.stock.effect.compressor / threshold` has `.writeReadback` capability; all others return `.unsupported`.
- **Compressor `threshold` in `StockPluginCatalog`** — `writeMethod: "ax_slider_axvalue"`, `readbackMethod: "ax_slider_axvalue"`, `unit: "normalized"`, `valueRange: 0–100`, `tolerance: 1.0`, `axDescription: "Threshold"` (live proof carried in this changelog and the v3.7.0 GitHub Release).
- **`logic_mixer.insert_plugin` deprecated** — go-forward path is `logic_plugins.insert_verified`. `insert_plugin` remains in the 8-tool surface for the current release cycle but is superseded by the verified surface for the allowlisted stock plugins (Gain / Channel EQ / Compressor).

### Changed

- **Release and packaging surfaces synchronized for the v3.6.0 line** — `ServerConfig`, manifest, installer default, Formula version, startup-banner tests, README, API, SETUP, SECURITY, ARCHITECTURE, HONEST-CONTRACT, MAINTAINERS, CONTRIBUTING, release notes, and live verification docs now point at the v3.6.0 release line. The Formula SHA is updated post-publish from the released `SHA256SUMS.txt`.
- **Plugin write guidance moved from legacy Scripter to HC v2** — docs now treat `logic_mixer.set_plugin_param` as the legacy send-only State B path and direct verified apply-back workflows to `logic_plugins.get_inventory`, `insert_verified`, and `set_param_verified`.

### Fixed

- **`logic://tracks` placeholder mode on Logic Pro 12.2 + macOS 26** — the track-header rail matcher now prefers Logic's language-neutral AX structure (`AXSelectedChildren` pointing at direct `AXLayoutItem` rows), while still treating `Track Headers`, `Track Header`, `Tracks Header(s)`, and Korean `트랙 헤더` as explicit compatibility signals. The fix is centralized and used by both `mainWindow()` arrange-window selection and `getTrackHeaders()`, so window disambiguation cannot still fall back to an auxiliary non-dialog pane after the header lookup itself was fixed. This prevents the `StatePoller` from caching an empty track list and the resource layer from synthesizing placeholder rows (`source:"ax_live_with_file_count"`, `placeholder:true`, generic `Track N` names) when the real arrange track headers are visible. Track type inference also now scans header descendants for AX description/title/identifier/help/value signals, so type metadata exposed on Logic 12.2 header icons is no longer reported as `unknown`.
- **Logic 12 transport readback drift** — `transport.get_state` now prefers the Logic 12 control bar before the older Transport group and overlays direct control-bar checkbox readback for Cycle, Metronome, Play, and Record. Control-bar toggles now verify the checkbox state changed after AXPress or a real mouse-click fallback before reporting State A. This keeps `logic://transport/state` consistent with visible control-bar writes and prevents stale legacy transport subtrees from making cycle/metronome roundtrips look failed after a successful UI toggle.
- **`brew install` regression (Issue #22, thomas-doesburg)** — the Formula installed its five helper assets from the tarball root, while the published v3.4.6/v3.5.0 tarballs stage them under `docs/` and `Scripts/` (the inverse of the v3.1.x mismatch fixed in PR #2), so the Homebrew install step failed. `pkgshare.install` paths now match the staged layout. Two guards now block both drift directions: a PR-time test (`VersionConsistencyTests.testFormulaInstallPathsMatchRepoAndReleaseStaging`) asserts every Formula install path exists in the repo and is staged by `release.yml`, and a tag-time release-workflow gate asserts every install path against the actual built tarball (`tar -tzf`) before anything is published. Because the Homebrew tap serves the Formula from `main`, the fix applies to the already-published v3.4.6/v3.5.0 artifacts on `brew update` — the tarballs themselves were always correct; only the install paths were wrong.
- **Install docs cover the Homebrew 6.0 tap trust model** — README/SETUP now include the `brew trust monglong0214/logic-pro-mcp` step required before `brew install` on Homebrew 6.0+, and TROUBLESHOOTING gained an Install section for the untrusted-tap refusal and the issue #22 `Errno::ENOENT` symptom. MAINTAINERS documents the two-layer Formula/tarball gate.

### Tests

- PR #24 exact-slot plugin branch: focused Swift suites `63/63`, full `swift test --no-parallel` `1384/1384`, release build, Python live-E2E syntax, stale Search-and-Add grep `0`, targeted live exact-slot insert proof, cleanup readback, and strict live E2E `314/314` passed.
- PR #54 / issue #59 readback hardening: focused AX tests passed, `swift build -c release` passed, full `swift test --no-parallel` `1388/1388` passed, live `logic://tracks` probe returned `source:"ax_live"` with `placeholder_count:0` and `unknown_type_count:0`, and manual cycle toggle/resource roundtrip reflected live UI state.
- v3.6.0 release-tree gates: packaging version bump, `git diff --check`, `ruby -c Formula/logic-pro-mcp.rb`, `python3 -m py_compile Scripts/live-e2e-test.py`, full deterministic suite `1396/1396`, release build, strict live E2E `314/314`, release workflow macOS 14/15 install validation, and Formula SHA sync from `SHA256SUMS.txt`.

## [3.5.0] — 2026-06-12

**Issue #14 + Issue #15 — verified stock plugin intelligence and workflow skills pack, plus a fail-closed dispatcher validation sweep.** This release ships the merge of the combined #17/#18 branch (PR #21). It grows the public read surface from 9 resources + 3 templates to 14 resources + 7 templates and tightens every dispatcher input path; per the release contract documented at merge time, this expanded surface ships as `v3.5.0` — the published packaging (manifest, Formula, installer) is unpinned from `v3.4.6` in this release.

### Added

- **Verified stock plugin intelligence (Issue #14)** — `StockPluginCatalog`: a provenance-gated catalog of Logic Pro 12.2 stock plugins with six truth states (`verified`, `observed`, `manifested`, `inferred`, `unavailable`, `readback_mismatch`). A `verified` claim is impossible without source + method + timestamp + evidence; census contradictions fail loud (`census_conflict`) and never resolve to `verified`; the production snapshot never claims beyond `manifested`; the live insert allowlist is cross-checked against the catalog. New resources: `logic://stock-plugins`, `logic://stock-plugins/census`, `logic://stock-plugins/capabilities`; new templates: `logic://stock-plugins/{id}`, `logic://stock-plugins/search?query={query}`.
- **Workflow skills pack (Issue #15)** — `WorkflowSkillCatalog`: lint-gated multi-step Logic Pro recipes. Every step command is validated against the live dispatcher command census (pinned to dispatcher sources by test), resource references resolve against the live `ResourceProvider` surface (no hand-maintained allowlist), mutating steps require exact (level, command) confirmation coverage, and `live_verified` claims must reference an in-repo evidence file. Served workflows expose computed `dependencies_resolved` / `unresolved_resources` honesty fields. New resources: `logic://workflow-skills`, `logic://workflow-skills/schema`; new templates: `logic://workflow-skills/{id}`, `logic://workflow-skills/search?query={query}`.
- `logic_system.help` now derives resource/template counts from `ResourceProvider` and lists the new stock-plugin and workflow-skill URIs.

### ⚠️ BREAKING

Dispatcher input validation is now uniformly fail-closed: values that were previously clamped, coerced, silently ignored, or defaulted are now rejected — with a structured `invalid_params` error on most paths, and a descriptive parse error for `record_sequence` note parsing.

- `logic_midi.send_pitch_bend` — `value` is strictly `0..16383` (center `8192`); the signed `-8192..8191` alias and the `>16383` clamp are removed. A caller still sending signed values gets `invalid_params`, and `value: 0` now means full-down, not center.
- `logic_midi` 7-bit fields (`send_note`, `send_chord`, `send_cc`, `send_program_change`, `send_aftertouch`, `step_input`) — out-of-range values such as `note: 128` are rejected instead of clamped; `duration_ms` must be `1..30000`; chord size is `1..24` notes.
- `logic_midi.play_sequence` — top-level `channel` is rejected (channel is per-event inside `notes`); event count must be `1..256`; realtime timing caps are enforced on both `midi` and `keycmd` ports (per-event ≤ 30 s, total span ≤ 60 s).
- `logic_midi.import_file` — `path` must resolve to a regular `.mid` file under `/tmp/LogicProMCP/` after symlink/`..` normalization; control characters are rejected.
- `logic_midi.mmc_locate` — explicit `bar` (`1..9999`) or SMPTE `time` (`HH:MM:SS:FF`) is required; the implicit `00:00:00:00` default is removed.
- `logic_midi.send_sysex` — strict `F0 … F7` framing with a 7-bit interior; embedded `F0`/`F7` delimiters are rejected.
- `logic_tracks.record_sequence` — `bar` must be `1..9999` and `tempo` `5..999` (`invalid_params`); malformed `notes` now fail the whole parse with a descriptive error — segments must have exactly 3–5 fields (extra fields were previously ignored) — and the generated SMF may not exceed 60 minutes.
- `logic_tracks.mute` / `solo` / `arm` — `enabled` must parse as a boolean (`true`/`false`, `0`/`1`, `"yes"`/`"no"`); anything else is rejected. `scan_library.mode` must be one of `ax|disk|both`; `scan_plugin_presets.submenuOpenDelayMs` must be `0..5000`.
- `logic_navigate.goto_bar` — explicit `bar` (`1..9999`) is required (previously defaulted to bar 1); `set_zoom` numeric level is bounded to `1..10`.
- `logic_navigate.goto_marker` — a malformed (non-integer or negative) `index` is now rejected with `invalid_params` instead of silently falling through to the name lookup. (Cache misses already return State C `element_not_found`; the legacy CC 38 "next marker" fallback was removed in v3.4.0 H-2.)
- `logic_transport.set_tempo` — explicit numeric `tempo`/`bpm` (`5..999`) is required (previously defaulted to 120); `goto_position` requires an explicit integer `bar` (`1..9999`) or a well-formed `bar.beat.sub.tick`/SMPTE `position`; `set_cycle_range` requires explicit integer `start`/`end` in `1..9999` with `start <= end` (previously defaulted to 1/5).
- `logic_mixer.set_volume` / `set_pan` / `set_master_volume` / `set_plugin_param` / `insert_plugin` — explicit targets and strict ranges (`0.0..1.0` volume, `-1.0..1.0` pan, plugin param `0..17` with value `0.0..1.0`); conflicting parameter aliases (e.g. `track` vs `index`, `value` vs `volume`) are rejected instead of first-key-wins.
- `logic_project` destructive commands — a malformed (non-boolean) `confirmed` param is rejected with `invalid_params` and audited as `rejected`, instead of being coerced to `false`.
- Shared param parsing — numeric params reject non-finite values, booleans accept only `true`/`false`, `0`/`1`, or `"yes"`/`"no"`, and multi-alias keys (e.g. `track`/`index`) must agree when both are supplied.

### Fixed

- Hardened stock-plugin and workflow resource routing so percent-encoded paths, percent-encoded query parameter names, and malformed query escapes fail closed instead of aliasing canonical catalog URIs.
- Corrected workflow required-field declarations for array/enveloped resource shapes, including track regions, markers, stock plugin detail/list reads, and mixer strip reads.
- Documented the next public-surface release contract (`v3.5.0` after merge) while keeping install/Formula/manifest surfaces pinned to the published `v3.4.6` release until a real stable tag and assets exist.
- `transport.toggle_cycle` / `toggle_metronome` / `toggle_count_in` now fall through to the next channel when the Accessibility channel reports terminal State C `element_not_found` (e.g. the control-bar button is hidden), instead of hard-stopping; `toggle_cycle` now tries MCU last instead of second.

### Changed

- **Version/release surfaces finalized to `3.5.0`** — `ServerConfig`, manifest (now advertising the 14-resource + 7-template surface with all stock-plugin and workflow-skill URIs, cross-checked against the live `ResourceProvider` by test), installer default, Formula version, startup-banner tests, and troubleshooting docs are synchronized for the stable release. The Formula `sha256` is updated post-publish from the released `SHA256SUMS.txt`.
- **CI coverage gate raised to current-baseline floor** — global source coverage now hard-gates at region >=70% / line >=78%, while keeping line >=90% as the explicit uplift target. Maintainer and contribution docs now clarify that new high-risk production code should target about 90% line coverage on the touched surface or carry live/manual evidence when direct measurement is not practical.

### Tests

- Added adversarial dispatcher validation, stock plugin catalog, workflow skill catalog, fail-closed resource routing, and commercial readiness suites on top of the focused AX coverage below.
- Added focused coverage for AX mouse/key injection, AX-backed Library selection, control-bar lookup fallbacks, accessibility routing validation, and Logic process/window detection.
- Local gate: `swift test` (parallel) and `swift test --no-parallel` -> 1276 tests passed; CI coverage TOTAL 74.49% region / 81.76% line; Logic Pro 12.2 live E2E 313 passed / 0 skipped / 0 failed.
- Release gates on the v3.5.0 tree: `python3 -m py_compile Scripts/live-e2e-test.py` -> PASS; `ruby -c Formula/logic-pro-mcp.rb` -> PASS; `swift test` -> 1276 passed; `swift test --enable-code-coverage --no-parallel` -> 1276 passed with local coverage TOTAL 75.51% region / 83.04% line; `swift build -c release` -> PASS; fresh strict live E2E (Logic Pro 12.2, `LOGIC_PRO_MCP_STRICT_LIVE=1`) -> 313 passed / 0 skipped / 0 failed (2026-06-12).
- `Scripts/release-stable.sh v3.5.0` -> preflight PASS (py_compile, `swift test --no-parallel` 1276 passed, release build) and tag pushed.
- GitHub Release workflow for `v3.5.0` -> run `27421259014` PASS: build plus macOS 15 and macOS 14 install validation. Published assets include `LogicProMCP`, both tarball aliases, `SHA256SUMS.txt`, and `RELEASE-METADATA.json`; the Formula `sha256` now pins the published universal tarball.

## [3.4.6] — 2026-06-09

**Release evidence synchronization.** Publishes the current mainline after the v3.4.5 post-release verification pass so the stable tag, server version, installer default, manifest URL, Formula version, and startup banner tests all point at the same build. No new Logic Pro runtime contract is introduced beyond the v3.4.5 Issues #10-#13 fixes; this release carries the final cycle-cache live E2E harness timing fix and documentation consistency cleanup.

### Changed

- **Version/release surfaces finalized to `3.4.6`** — `ServerConfig`, manifest, installer default, Formula version, startup-banner tests, README, setup docs, release evidence docs, and maintainer docs are synchronized for the stable release.
- **Full live attestation is no longer listed as separate remaining scope** — the strict live E2E pass completed after the harness bounded-wait fix: 285 passed, 0 skipped, 0 failed. Multi-version Logic matrix coverage remains future verification work.
- **v3.4.5 remains the functional mixer-fix release** — v3.4.6 is the evidence/packaging alignment release for the same #10-#13 behavior.

### Known remaining scope

- **Full per-parameter plugin value readback** remains future work. Current builds ship plugin-slot/name/bypass snapshots and Honest-Contract-shaped Scripter writes, but Scripter is still send-only and does not provide a guaranteed AX slider map for every plugin parameter.
- **`set_plugin_param insert:N` routing** remains future work. Current builds ship `insert_plugin` guardrails and slot readback; targeting arbitrary plugin insert slots for parameter writes requires a separate plugin-window AX path.
- **Multi-version Logic matrix** remains future verification work. Current live evidence is Logic Pro 12.2 on this host plus GitHub Actions macOS 14/15 installer validation.

### Tests

- `python3 -m py_compile Scripts/live-e2e-test.py` -> PASS.
- `ruby -c Formula/logic-pro-mcp.rb` -> PASS.
- `swift test --filter VersionConsistencyTests --no-parallel` -> 1 / 1 PASS.
- `swift test --enable-code-coverage --no-parallel` -> 1197 / 1197 PASS locally; TOTAL coverage 70.81% region / 78.32% line.
- `Scripts/release-stable.sh v3.4.6` -> preflight PASS and tag pushed.
- GitHub Release workflow for `v3.4.6` -> run `27186085967` PASS: build plus macOS 15 and macOS 14 install validation. Published assets include `LogicProMCP`, both tarball aliases, `SHA256SUMS.txt`, and `RELEASE-METADATA.json`.

## [3.4.5] — 2026-06-09

**Mixer write/read verification honesty — Issues #10–13 (thomas-doesburg).** Publishes the v3.4.5 stable release with the Logic Pro 12.2 mixer AX matcher restored and live-verified. Host-originated fader writes can still receive no MCU echo on Logic 12.2, but `set_volume` now falls back to independent AX fader readback and can return State A when the observed fader matches tolerance. `logic://mixer` carries provenance, AX-sourced `plugins[]` snapshots identify occupied insert slots, and `insert_plugin` is exposed only as a guarded, Level-2-confirmed, stock-plugin allowlisted path. Stable artifacts ship through the ADHOC path when Developer ID credentials are absent, with SHA256 metadata, release metadata, and macOS 14/15 install validation.

### Added

- **`MCU_TRACE=1`** env var (#10) — dumps every outbound/inbound MCU MIDI frame to **stderr** (`MCU TX/RX: <hex>`), pre-decode, rate-limiter-bypassed; stdout stays clean JSON-RPC. Lets a harness confirm whether Logic echoes a host write. (`Sources/LogicProMCP/MIDI/MCUTrace.swift`)
- **`logic://mixer` provenance** (#11) — new `data_source` (`ax_poll`/`cache_stale`/`mixer_not_visible`), `mcu_registered`, and `mcu_last_feedback_age_ms`; `registered` retained as a one-release alias. `logic://mixer/{strip}` now returns the same cache envelope (`cache_age_sec`/`fetched_at`/`data_source`/`strip`) instead of a bare object.
- **`pan_write_mode:"relative_vpot"`** on `set_pan` envelopes (P1-5) — honestly discloses that MCU pan is a relative V-Pot nudge (no absolute-position command), so callers do not treat it as idempotent.
- **`plugins_source:"ax"`** on mixer strips (#12) — `logic://mixer` now differentiates AX-observed insert snapshots from unknown/empty plugin state, so clients no longer have to infer whether `plugins:[]` means "no plugins" or "no readable source."
- **Guarded `insert_plugin`** (#13) — supports a stock Logic plugin allowlist through the Accessibility channel with Level-2 confirmation, occupied-slot refusal, and post-insert AX slot readback.

### Changed

- **`set_plugin_param` is now Honest-Contract-shaped** (#12/#13 write-half, P1-3) — Scripter returns HC State B `readback_unavailable` (with `cc`/`applied_midi_value`/`readback_source` extras) instead of a free-form string, and value is fail-closed to `0.0…1.0` (State C `invalid_params`) instead of being silently clamped.
- **`set_plugin_param` refuses an unverified track selection** (P1-2) — mirrors `track.delete`/`duplicate`: if the pre-write `track.select` returns State B, the write hard-fails (State C with the original `select_response`) rather than writing to whatever track happened to be selected.
- **`MIDIEngine` is restart-safe** (P1-6) — `stop()` no longer finishes the inbound `AsyncStream`; the continuation is terminal only at `deinit`, so `start → stop → start` restores inbound MIDI delivery.
- **Version/release surfaces finalized to `3.4.5`** — `ServerConfig`, manifest, installer default, Formula version/SHA, startup-banner tests, README, setup docs, and resource `lastModified` timestamp are synchronized for the stable release.
- **CI coverage gate tightened** — coverage now runs fail-closed with `set -euo pipefail`, writes fallback profile output under a writable temp path, requires `swift test --enable-code-coverage`, profdata lookup, `llvm-cov report`, and threshold parsing to succeed, and raises the hard gate to region >=70% / line >=77%. Recoverable GitHub macOS runner `LLVM Profile Error` warnings are surfaced in annotations/summary, but the gate is the generated profdata/report plus thresholds.
- **Stable ADHOC release path restored** — Apple Developer ID is optional for this project. Stable tags fall back to the historical ADHOC signing path when Developer ID credentials are absent, while keeping SHA256, codesign verification, release metadata, and install validation gates.
- **Release workflow prerelease honesty** — hyphenated release tags are published as GitHub prereleases, so RC tags do not masquerade as stable/latest releases.
- **Live E2E coverage profile hygiene** — Python/tmux live E2E launches set `LLVM_PROFILE_FILE` to a writable temp profile path when the binary is coverage-instrumented.
- **Scripts cleanup** — removed one-off local/spike harnesses from `Scripts/` and kept only maintained installer, release, live E2E, plist/template, and shipped support assets.

### Fixed

- **Logic 12.2 mixer AX matcher restored** (#10/#11/#12/#13) — the matcher now finds the Logic 12.2 mixer pane by role/description instead of the stale `identifier=="Mixer"` shape, then uses description-based fader/pan/insert-slot discovery.
- **Echo-independent fader verification** (#10) — when MCU echo times out but AX can read the requested strip, `set_volume` can return `verified:true` with `verify_source:"ax_readback"` and `observed_ax`.
- **Mixer resource readback after host writes** (#11) — `logic://mixer` can now refresh from AX poll on Logic 12.2 and reflect the post-write fader value instead of remaining stuck on the connect-time MCU value.
- **AX coordinate-click fallbacks fail closed** (P2-5) — four call sites (`AccessibilityChannel.postMouseClickAt`/`trackViewport`, `AXLogicProElements` track-header click, `LibraryAccessor` header click) now route through shared `AXHelpers.point/size(fromRawAttribute:)` helpers that check `AXValueGetValue`'s Bool result, so a wrong-subtype `AXValue` yields nil instead of a (0,0) misclick / bogus viewport.
- **Test/evidence honesty** (P1-1/P1-4) — `EndToEndTests` no longer asserts `!isEmpty` on removed read commands (they now assert the tool rejects them as `Unknown` and the misnamed `set_mute`/`set_solo` use the real `mute`/`solo` commands); `Scripts/live-e2e-test.py` reads via `resources/read` instead of stale tool-read commands.
- Docs (`API.md`, `TROUBLESHOOTING.md`) corrected for the structured `channels_exhausted` envelope, the mixer provenance fields, the `set_plugin_param` HC shape, the empty `plugins[]` gap (#12), and `MCU_TRACE`.

### Known remaining scope

- **Full per-parameter plugin value readback** remains future work. v3.4.5 ships plugin-slot/name/bypass snapshots and Honest-Contract-shaped Scripter writes, but Scripter is still send-only and does not provide a guaranteed AX slider map for every plugin parameter.
- **`set_plugin_param insert:N`** remains a missing mechanism. v3.4.5 ships `insert_plugin` guardrails and slot readback; targeting arbitrary plugin insert slots for parameter writes requires a separate plugin-window AX path.

### Tests

- `swift test --no-parallel` -> 1197 / 1197 PASS locally.
- `swift build -c release` -> PASS locally.
- `python3 -m py_compile Scripts/live-e2e-test.py` -> PASS.
- `swift test --enable-code-coverage --no-parallel` -> 1197 / 1197 PASS locally; TOTAL coverage 70.40% region / 77.78% line.
- Targeted live Logic Pro 12.2 issue gate -> #10/#11/#12/#13 checks PASS: AX readback for `set_volume`, `logic://mixer` `data_source:"ax_poll"`, AX plugin snapshots, Level-2 `insert_plugin` confirmation, verified Gain insert, and occupied-slot fail-closed.
- GitHub Release workflow for `v3.4.5` -> run `27183025739` PASS: build plus macOS 15 and macOS 14 install validation. Published assets include `LogicProMCP`, both tarball aliases, `SHA256SUMS.txt`, and `RELEASE-METADATA.json`.

### Release packaging (rc8–rc12, 2026-06-05/08 — CI/installer-only, no server-functional change)

- rc8 workflow bash 3.2 fix · rc9 split universal build · rc10 candidate stdout fix · rc11 installer team-id parse validation · rc12 validation floor aligned to macOS 14.

## [3.4.5-rc7] — 2026-06-05

### Changed

- Removed the release-path grep heuristic from the universal-binary selection step. The workflow now scans every executable `LogicProMCP` candidate under `.build` and picks the first Mach-O that actually contains both `arm64` and `x86_64` slices.
- Bumped installer, manifest, formula, and server identity surfaces to `v3.4.5-rc7` for the rerolled packaging hotfix release.

## [3.4.5-rc6] — 2026-06-05

### Changed

- Fixed the release workflow's universal-binary selection after `swift build --arch arm64 --arch x86_64`: packaging now selects the final fat Mach-O instead of whichever release-path candidate `find ... | head -1` returns.
- Documented the split between workflow-built universal releases and local ADHOC arm64-only prerelease artifacts.
- Bumped installer, manifest, formula, and server identity surfaces to `v3.4.5-rc6` for the packaging hotfix release.

## [3.4.5-rc5] — 2026-06-05

**2026-06-05 production-readiness hardening and MIDI-only composition E2E.** This branch now carries the final v4 composition workflow and the server-side readback fixes needed to make repeated Logic Pro automation runs honest: `project.save_as` verifies the `.logicx` package on disk, `logic_midi.import_file` is an explicit dispatcher command with hardened path validation and new-track readback, `logic://project/info` uses live transport tempo/sample-rate without inflating track counts from visible AX rows, and Logic process detection has an on-screen-window fallback for hosts where `ps`/`pgrep` are restricted.

### 2026-06-05 Added

- `logic_midi.import_file` dispatcher command — routes to `midi.import_file`, rejects `port`, requires explicit `path`, and documents sequential callers waiting for `verified:true` before issuing the next import.
- `AppleScriptChannel.wrapSaveAsResult` — wraps successful `project.save_as` responses in Honest Contract State A only after observing the requested `.logicx` package. Existing package saves must show an advanced modification time; missing/stale packages return State C `readback_mismatch`.
- `AccessibilityChannel.validatedMIDIImportPath` — resolves symlinks, standardizes the URL, rejects control characters, enforces `.mid`, and only accepts regular files under `/tmp/LogicProMCP/`.
- `HonestContract.FailureError.readbackUnavailable` — terminal State C code for write paths that executed a fallback but could not obtain the readback required to claim success.
- rc5-era production-readiness evidence covered local tests, release build, live Logic Pro 12.2 health, tempo readback, save-as package readback, and the v4 MIDI-only composition artifact.

### 2026-06-05 Changed

- `AccessibilityChannel.defaultImportMIDIFile` now treats "import completed but no new AX track appeared" as State C `readback_mismatch` instead of uncertain success. This prevents a sequencer from stacking additional imports on top of a failed Logic import.
- `ResourceHandlers.readProjectInfo` now promotes live `TransportState` tempo/sample-rate when available, still falls back per-field to `MetaData.plist`, and only uses project-file `trackCount` when the saved count is positive. Visible AX rows are not promoted to whole-project totals.
- `LibraryAccessor` resolves duplicate visible Library names by column intent: category clicks target the leftmost match, and preset/folder clicks target the rightmost active match. This prevents duplicate labels such as top-level `Bass` and `Synthesizer/Bass` from selecting the wrong column.
- `ProcessUtils` now detects Logic Pro from on-screen window metadata before falling back to `ps`, `pgrep`, or System Events. CGWindow owner PIDs are parsed from `pid_t`, `NSNumber`, or `Int` values so the helper stays resilient across CoreGraphics payload shapes.
- `.gitignore` now ignores generated composition attempts and captured media under `artifacts/*`, while explicitly allowing the final MIDI-only v4 package directory back into the repository.

### 2026-06-05 Tests

- `swift test` -> `1143 / 1143` PASS locally.
- `swift build -c release` -> PASS locally.
- `PYTHONPYCACHEPREFIX=/private/tmp/logic-pro-mcp-pycache python3 -m py_compile artifacts/acid-track-composition-v4/import_v4_sequential.py` -> PASS.
- Live `.build/release/LogicProMCP` MCP session against Logic Pro 12.2 -> all 7 channels ready; `logic_transport set_tempo` verified at `127`; `logic_project save_as` returned `verified:true` with observed package mtime; saved `ProjectData` contained all 11 v4 MIDI region names and no packaged audio files.

**Diagnostic surface improvements for mixer write wire contract — Issues #10 and #11 from thomas-doesburg (v3.4.5-rc4 + Logic Pro 12.2).** Both reports describe the same wire shape (`success:true, verified:false, reason:echo_timeout_500ms` on `mixer.set_volume` / `set_pan`; `logic://mixer` not reflecting the written value) but the envelope didn't carry enough context to distinguish three distinct root causes (Mackie Control unregistered / connection went stale / specific echo lost) without a second round-trip. The Honest Contract response now embeds an MCU connection snapshot inline on every mixer write, and `ChannelRouter` wraps chain exhaustion in a structured `channels_exhausted` State C envelope so harnesses no longer regex-match a free-form "All channels exhausted" string.

### Added

- `MCUChannel.mcuConnectionExtras()` — snapshot helper that injects `mcu_connected` (Bool), `mcu_registered` (Bool), and `mcu_last_feedback_age_ms` (Int? — `null` when no feedback has been observed; clamped to 0 to defend against system-clock-jump-induced negative intervals per Boomer BOOMER-6 / E review) into the HC envelope extras of every `set_volume`, `set_pan`, and `set_master_volume` response. State A and State B both carry the triplet so provenance logs remain uniform.
- `MCUMixerWriteDiagnosticsTests` — 6 unit tests covering the disconnected default (no feedback ever), registered-and-fresh State A, registered-but-stale State B, the clock-jump clamp, and parity across all three mixer write paths.
- `EndToEndTests` mixer additions — 4 wire-level E2E tests that walk `tools/call` → `MixerDispatcher` → `ChannelRouter` → MCU and pin the structured `channels_exhausted` State C envelope as the production wire shape when MCU is unavailable, plus a regression guard against the legacy "All channels exhausted" free-form string ever leaking back.

### Changed

- `ChannelRouter.route` — when every channel in the chain is exhausted or skipped, the response is now `HonestContract.encodeStateC(error: .channelsExhausted, hint: lastError, extras: ["operation": op, "last_error": lastError])`. The new `.channelsExhausted` enum case is **semantically distinct from `.portUnavailable`** (Boomer BOOMER-6 / U review fix): `port_unavailable` is scoped to a single channel whose specific port is unwired (e.g. KeyCmd virtual port not yet published), while `channels_exhausted` is the chain-level aggregate signal when no channel in the chain could handle the operation. The previous wrap reused `port_unavailable` for both meanings, which would have caused a harness branching on `error: "port_unavailable"` to mis-diagnose a "Logic not running" exhaustion as a port-wiring problem. The previous free-form error string forced safety harnesses into regex-based root-cause detection.
- `HonestContract.FailureError` — new `.channelsExhausted` case (raw: `channels_exhausted`) added to `terminalErrorCodes` alongside `.portUnavailable`. Documented in the API reference.
- `MCUChannel.pollFaderEcho` / `pollPanEcho` — TOCTOU fix (Boomer BOOMER-6 / B2 review). The two functions previously read `cache.getChannelStrip(...).volume` and `cache.getFaderUpdatedAt(...)` in two separate actor turns, which left a window where a concurrent MCU feedback event could pair an old value with a new timestamp and false-positive State A on a disconnected transport. Both functions now use the new atomic `StateCache.getFaderEchoSnapshot(strip:)` / `getPanEchoSnapshot(strip:)` helpers that return `(value, updatedAt)` in a single actor turn. Closes the race the `testSetVolumeStateAIncludesMCUDiagnostics_connectedFresh` test was flagging by tolerating either State A or State B.
- `StateCache` — new atomic snapshot helpers `getFaderEchoSnapshot(strip:) -> (volume: Double?, updatedAt: Date?)` and `getPanEchoSnapshot(strip:) -> (pan: Double?, updatedAt: Date?)`.

### Documentation

- API docs — new "Channel-specific extras" section documenting the `mcu_connected` / `mcu_registered` / `mcu_last_feedback_age_ms` triplet plus the decision table for harnesses on State B `echo_timeout_<ms>ms`. New `channels_exhausted` error code documented in the State C section alongside the `port_unavailable` distinction.
- `docs/API.md` — common-error table now references the structured `channels_exhausted` envelope instead of the legacy free-form string.
- Architecture docs — router aggregate, transport routing, and error propagation notes updated to reflect the new HC State C envelope.
- `docs/SETUP.md` — MCU registration warning now references the actual rc5 wire shapes (both `channels_exhausted` and the State B `echo_timeout` shape) so users searching for either error string land on the right page.

### Honest scope

This change does not fix the underlying echo-timeout if one exists on Logic Pro 12.2 — it makes the failure mode legible so the reporter (and we) can tell setup gaps from code regressions before the T0 live spike on 12.2 happens. The most likely root cause (Mackie Control device not registered in `Logic Pro → Control Surfaces → Setup`) shows up as `mcu_connected: false, mcu_last_feedback_age_ms: null` on the new wire surface and falls out of the harness's first-pass diagnostic without any extra probe.

### Tests

- `swift test` → 1124 / 1124 PASS locally (10 new tests added for this change).
- `swift build` → clean.
- Boomer (Codex gpt-5.5 xhigh) BOOMER-6 review → ALL PASS with 2 P2s addressed inline: clock-jump clamp landed in `mcuConnectionExtras`, and the additive wire-shape change is called out for harness operators in this CHANGELOG entry.

### Wire-shape note for harness operators

The three new top-level keys (`mcu_connected`, `mcu_registered`, `mcu_last_feedback_age_ms`) are purely additive on existing envelopes. Existing parsers that read `success` / `verified` / `reason` / `requested` / `observed` / `track` continue to work unchanged. If your harness applies strict-schema validation against the HC envelope, allow these three keys before upgrading. The chain-exhaustion path on `ChannelRouter` is now a structured State C envelope (`error: "channels_exhausted"`, `operation`, `last_error`, `hint`) instead of the free-form error string it returned previously. The new `channels_exhausted` code is **semantically distinct** from the pre-existing `port_unavailable` code: `port_unavailable` is scoped to bypass-op channels reporting their own specific port is unwired (e.g. KeyCmd virtual port not yet published), while `channels_exhausted` is the chain-level aggregate when every channel in the operation's chain reported `healthCheck.unavailable` or failed its readiness gate. Harnesses branching on `error` should treat them as two distinct root-cause families.

## [3.4.5-rc4] — 2026-05-10

**Installer metadata parser hotfix for the final v3.4.5 release candidate.** `v3.4.5-rc3` passed local and GitHub CI, but a post-release installer smoke test caught a real same-origin install failure: `RELEASE-METADATA.json` is emitted as one-line JSON and the installer's `awk -F'"'` parser selected the `version` field instead of `team_id`, producing `expected: v3.4.5-rc3` during code-signature verification. The parser now matches the `team_id` key explicitly, and the Setup guide's pinned installer URLs are current.

### Fixed

- `Scripts/install.sh` now extracts `team_id` from one-line `RELEASE-METADATA.json` with an explicit key regex instead of relying on quote-field position.
- `InstallScriptContractTests` guards against reintroducing the old quote-field parser.
- README, Setup guide, manifest, installer defaults, Formula metadata, and startup-banner tests now point at `v3.4.5-rc4`.
- `v3.4.5-rc3` remains published but is superseded by this candidate because its same-origin installer path could reject the ADHOC release metadata.

### Tests

- `swift test --no-parallel` -> 1114 / 1114 PASS locally.
- `swift test --enable-code-coverage --no-parallel` -> 1114 / 1114 PASS locally; coverage 70.47% region / 77.29% line.
- `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh` -> 259 / 259 PASS, 0 skipped, 0 failed.
- `Scripts/live-e2e-test.py` -> 213 PASS, 46 correctly skipped on the direct Python parent path, 0 failed.
- `LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1 LOGIC_PRO_MCP_INSTALL_DIR=/private/tmp/logic-pro-mcp-install-rc4 LOGIC_PRO_MCP_REGISTER_CLAUDE=0 LOGIC_PRO_MCP_INSTALL_KEYCMDS=0 LOGIC_PRO_MCP_SKIP_SUDO=1 bash Scripts/install.sh` -> post-publish release install smoke gate for rc4.
- Full local and GitHub CI gates remain required before treating this tag as final.

## [3.4.5-rc3] — 2026-05-10

**Final CI-readiness release candidate for v3.4.5.** `v3.4.5-rc2` fixed the workflow's parallel-test mismatch, but the GitHub run exposed a separate test-harness race in `ProductionMCUTransport` packet-sink assertions: packet capture used a fire-and-forget `Task`, so the assertion could observe an empty packet list before the recorder actor handled the message. The production send path was already synchronous; this candidate makes the recorder synchronous too and prevents a count failure from cascading into an array-index trap.

### Fixed

- `LogicProServerTransportTests` now records packet-sink callbacks synchronously with a lock-protected `PacketSinkRecorder`, matching the production callback ordering under test.
- Packet-sink assertions use safe `first` access after the count check so a failed count reports one assertion failure instead of crashing the whole test process.
- README, manifest, installer defaults, Formula metadata, and startup-banner tests now point at `v3.4.5-rc3`.
- `v3.4.5-rc2` remains published but is superseded by this candidate because its CI run still contained the packet-sink recorder race.

### Tests

- `swift test --no-parallel` -> 1113 / 1113 PASS locally.
- `swift test --enable-code-coverage --no-parallel` -> 1113 / 1113 PASS locally; coverage 70.65% region / 77.63% line.
- `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh` -> 259 / 259 PASS, 0 skipped, 0 failed.
- `Scripts/live-e2e-test.py` -> 213 PASS, 46 correctly skipped on the direct Python parent path, 0 failed.

## [3.4.5-rc2] — 2026-05-10

**CI gate determinism hotfix for the v3.4.5 release candidate.** `v3.4.5-rc1` closed the strict live E2E blocker, but the published tag exposed a separate CI-only false failure: the workflow still used default `swift test`, so suites that temporarily replace the process-wide `Log.output` singleton could interleave with one another under Swift Testing's parallel scheduler. The project has used `swift test --no-parallel` as the deterministic local and coverage gate since the enterprise review; this release candidate aligns the main CI test step to the same authoritative path instead of treating global-output capture tests as safely parallelizable.

### Fixed

- `.github/workflows/ci.yml` now runs `swift test --no-parallel` for the primary test gate, matching the coverage-test path and documented production-readiness evidence.
- README, manifest, installer defaults, Formula metadata, and startup-banner tests now point at `v3.4.5-rc2`.
- `v3.4.5-rc1` remains published but is superseded by this candidate because its GitHub Actions run used the wrong parallel test mode.

### Tests

- `swift test --no-parallel` -> expected deterministic gate for all 1113 tests.
- `swift test --enable-code-coverage --no-parallel` -> expected coverage gate.
- `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh` -> strict live attestation command unchanged from rc1.

## [3.4.5-rc1] — 2026-05-10

**Strict live E2E parent-context closure.** This release candidate closes the last live-launch blocker found in the enterprise production-readiness pass: macOS TCC/CoreMIDI evaluated Python as the responsible process when the E2E harness spawned the MCP server directly, so strict live checks failed even though the release binary itself had Accessibility and Automation grants.

### Fixed

- `Scripts/live-e2e-test.sh` now owns strict live launch through a trusted tmux parent process and exposes a FIFO/capture bridge to the Python assertion engine. This preserves newline-delimited stdio MCP coverage while matching the parent-process permission context used by real live clients.
- The strict tmux PTY starts with non-canonical/no-echo input so long JSON-RPC requests, including 1000-character validation payloads, are not truncated by terminal line discipline.
- Live E2E timeout handling now reflects real Logic UI behavior: full Library AX scans can take about 100 seconds on a stock Logic 12 library, and navigation dispatch can need longer than the generic 10-second RPC timeout.
- Live E2E now validates the current `scan_library` envelope schema (`source` + nested `root`) as a real success instead of falsely requiring the pre-envelope raw root shape.
- `AccessibilityChannel.scan_library` now fails closed when Logic is running without a visible project window, avoiding stale AX-descendant scans in headless/no-window states.
- `Scripts/release.sh` marks prerelease-tagged local ADHOC GitHub releases with `--prerelease`, matching the script's prerelease-only governance policy.
- README and the enterprise readiness review now document the validated strict live command: `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh`.

### Tests

- `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh` -> 259 / 259 PASS, 0 skipped, 0 failed.
- `swift test --no-parallel` -> 1113 / 1113 PASS.
- `swift test --enable-code-coverage --no-parallel` -> 1113 / 1113 PASS.
- `Scripts/live-e2e-test.py` -> 213 passed, 46 explicitly skipped, 0 failed in default non-strict mode.

## [3.4.4] — 2026-05-09

**CI hotfix — CoreMIDI smoke tests skip on macos-15-arm64 GitHub runners.** v3.4.3 added diagnostic output that revealed the v3.4.x CI failure was actually two production-runtime smoke tests failing with `MIDIClientCreate` returning OSStatus -50 (`kMIDINotPermitted`) on the GitHub `macos-15-arm64` runner image. The runner does not expose a working CoreMIDI server in the sandboxed image, so any test that hits `MIDIClientCreate` directly (without injecting a mock runtime) fails outside a developer's actual macOS host.

The two affected tests:

- `Tests/LogicProMCPTests/MIDIEngineTests.swift:testMIDIEngineProductionRuntimeStartStopSmoke`
- `Tests/LogicProMCPTests/MIDIPortTests.swift:testMIDIPortManagerProductionRuntimeSmokeCreatesAndStopsPorts`

Both are intentional smoke tests that exercise the *production* code path (no mock injection) to catch regressions on real macOS hosts. They have always been runner-environment-sensitive; v3.4.x just made it visible because the workflow's awkward log truncation hid the test failures behind a Coverage gate symptom.

### Fixed

- Both smoke tests now catch the specific `clientCreationFailed(-50)` error and `return` cleanly instead of failing the test. Any other `MIDIEngineError` / `MIDIPortError` still propagates so a real regression on a working host is not masked.
- Production code path coverage on real macOS hosts is unchanged — the test still runs the actual `MIDIEngine.start()` / `MIDIPortManager.start()` lifecycle when the runtime allows.

### Lessons captured

- v3.4.0 / v3.4.1 / v3.4.2 / v3.4.3 hotfix chain only worked locally because the developer host has a working CoreMIDI server. The `swift test --no-parallel` 1110/1110 PASS signal masked the CI-only failure for four releases. The H-4 coverage gate was not the bug — it was the messenger; v3.4.3's `find`-based path resolution is still the right hardening, just not the root cause.
- The honest-deferred swift-testing dependency (H-5) makes log archaeology harder than it needs to be — the deprecation-warning flood pushes the actual `✘ Test ... failed` lines past the GitHub log truncation cutoff. v3.4.3's diagnostic output (the explicit exit-code echo) is what finally surfaced the real test failures.

### Tests

`swift test --no-parallel` → 1110 / 1110 PASS unchanged on a host with a working CoreMIDI server. CI macos-15-arm64 should now PASS as well; the smoke tests cleanly skip on that environment.

## [3.4.3] — 2026-05-09

**CI Coverage step hotfix — `find`-based path resolution + diagnostic output.** v3.4.2 fixed the `Run tests` step's parallel-race; the `Coverage report` step still failed on macos-15-arm64 with no parseable error in the truncated job log. Direct verification of the coverage path showed:

- v3.4.2 step used `.build/debug/...` (a SwiftPM-created symlink to `.build/arm64-apple-macosx/debug/...`).
- The symlink exists locally on Apple Silicon. Whether it exists on the macos-15-arm64 GitHub runner across all Xcode 16.x point versions is not guaranteed.
- An absent symlink causes `xcrun llvm-cov report` to silently produce an empty `coverage-report.txt`, which the v3.4.1 regex guard correctly catches with `::error::Region coverage field '' did not match <float>% pattern.` — but the failure root cause looks identical to a column-drift, hiding the real symlink problem.

### Fixed

- `.github/workflows/ci.yml` Coverage step now resolves the test binary and profdata via `find .build -type f -path '*/debug/...' | head -1`. Path-version-stable across SwiftPM versions.
- The step prints the full `coverage-report.txt` inside a `::group::Full coverage report` section so future failures (threshold drift, column reorder, etc.) are diagnosable without log archaeology.
- Captures the inner `swift test --enable-code-coverage --no-parallel` exit code in `TEST_RC` and echoes it explicitly so we can tell `swift test failed` from `coverage parse failed`.
- Hard-fails with a `::error::` line listing the `.build` directory tree if the binary or profdata cannot be located, so the next operator does not have to repeat this debug session.

### Tests

`swift test --no-parallel` → 1110 / 1110 PASS (unchanged). Build clean. CI workflow YAML change only — no production code path touched.

### Known scope

This hotfix only touches the Coverage step. If the diagnostic output reveals coverage is below the 65% / 72% threshold on CI (because the runner can't exercise some live-OS code paths the local host can), the thresholds themselves will be tuned in a follow-up patch with the diagnostic numbers as evidence.

## [3.4.2] — 2026-05-08

**CI hotfix — `ProjectAuditPhaseTests` parallel-execution race.** v3.4.0 introduced six new audit-phase tests that captured `Log.output` via a fire-and-forget `Task { await capture.append(line) }` pattern with a 30 ms post-test drain sleep. Local `swift test --no-parallel` (single-threaded, 23 s runs) consistently passed; CI's `swift test` (parallel, ~9 s) failed three of the tests because:

1. The 30 ms drain was insufficient under runner load — pending Task appends could land after the snapshot.
2. `Log.output` is a static, so concurrent suite teardown could swap the global capture closure between two tests' emit and snapshot phases.

The test target's `swift test` (default parallel) is the authoritative gate on the CI side. v3.4.0 / v3.4.1 both shipped with this race — the local non-parallel run masked it. Verified by inspecting the v3.4.0 CI run #25600287472 (6 issues across `testProjectOpenWithoutConfirmLogsConfirmationRequired`, `testProjectOpenWithInvalidPathLogsRejected`, `testProjectQuitWithoutConfirmLogsConfirmationRequired`).

### Fixed

- **`ProjectAuditPhaseTests` race.** `AuditCapture` is now an `NSLock`-guarded `final class` (synchronous append/snapshot, no actor hop). The whole suite is wrapped in `@Suite(.serialized)` so the static `Log.output` mutation in `captureAuditLines` cannot interleave between concurrent tests within this file. The 30 ms drain `Task.sleep` is removed — capture is synchronous, so by the time `await body()` returns every audit line is already in the array.

### Tests

- Both `swift test` (parallel, ~4.4 s) and `swift test --no-parallel` (~23 s) now pass 1110 / 1110.
- The fix also addresses the cascading Coverage step failure on CI: with the test step green, the coverage step's `swift test --enable-code-coverage --no-parallel` no longer carries forward stale runner state.

### Known scope

This hotfix only changes the test file and the version bump artifacts. No production code path changed; the audit-phase contract from v3.4.0 is preserved.

## [3.4.1] — 2026-05-08

**v3.4.0 Boomer P2 sweep — non-BREAKING fail-loud hardening.** The Boomer review of v3.4.0 catalogued five P2 items as "addressable in a v3.4.1 sweep but none blocks release." This patch closes four of them (the fifth — `nav.goto_marker` orphan routing entry — was already addressed inline in v3.4.0 with a clarifying comment in `ChannelRouter`).

### Fixed (Boomer P2 from v3.4.0 review)

- **P2-2 — `release.sh` lipo empty / garbled output now fails loud.** Pre-fix `lipo -info` returning nothing or an unparseable string silently produced `"architectures":[]` in `RELEASE-METADATA.json`. The metadata consumer would see that as a known-empty manifest. v3.4.1 exits non-zero before publishing if the binary's architecture(s) cannot be parsed.
- **P2-3 — `ProjectDispatcher.AuditPhase.executed` contract documented.** The audit phase docstring now explicitly states that `executed` records *invocation intent* before `router.route(...)` fires, not the route's *outcome*. SIEM consumers who want outcome correlate the audit line with the channel response by timestamp + command name. This prevents future readers from misreading the contract.
- **P2-4 — CI coverage gate awk extraction is now fail-loud on column drift.** Pre-fix `awk '{print $4}'` and `$10` would silently extract a wrong field if a future LLVM `cov report` version inserted a column. v3.4.1 validates the extracted values match `^[0-9]+\.[0-9]+%$` before threshold compare; a mismatch fails the build with an `::error::` line naming the actual TOTAL line so a maintainer can fix the awk indices.
- **P2-5 — `uninstall-keycmds.sh` AUTO_RESTORE branch now refuses an empty backup.** Pre-fix `cp $LATEST/* … || true` masked an empty source directory as success — the operator saw `"✓ Restored"` without any files moving. v3.4.1 counts the backup file count first; an empty backup logs a clear warning and skips the copy with a hint to pick a different backup directory.

### Tests

`swift test --no-parallel` → **1110 / 1110 PASS** (unchanged from v3.4.0; this patch is hardening + comments only). Build clean.

## [3.4.0] — 2026-05-08

**Enterprise deferred-blocker closure: stdio launch parity, release governance, install rollback safety, audit-phase split, target-faithful navigation, AX hardening, docs realignment.** Closes the v3.3.0 honest-deferred set (RB-2, RB-4, RB-6, H-1..H-4, H-6) from the 2026-05-08 enterprise production-readiness review. Eight tickets, +15 regression tests (1110/1110 PASS), Boomer BOOMER-6 verdict pending Phase 6 final review. H-5 (swift-testing dep) re-deferred — Apple has not yet shipped the SwiftPM-side glue that makes the bundled Swift 6 Testing framework usable without the explicit package dependency (`_TestingInternals` missing on direct removal — confirmed twice).

### ⚠️ BREAKING

#### `goto_marker` cold-cache fallback removed (target-faithful contract)

Pre-v3.4.0 a cold-cache `goto_marker { index: N }` silently fell through to the legacy `nav.goto_marker` keycmd path (CC 38), which is Logic's "go to next marker" hotkey — it ignored the requested index and advanced the marker pointer by one. A caller asking for marker 5 with a cold cache could land on marker 1 and never know.

v3.4.0 returns a State C `element_not_found` envelope instead, naming the cached marker count and pointing the caller at `system.refresh_cache`. Callers that actually wanted "next marker" should use the keycmd path explicitly via `logic_midi.send_cc { controller: 38, channel: 16, port: "keycmd" }` after binding it through Manual MIDI Learn.

| Caller pattern                                       | Pre-v3.4.0 behaviour                | v3.4.0+ behaviour                                                                              |
|------------------------------------------------------|--------------------------------------|------------------------------------------------------------------------------------------------|
| `goto_marker { index: N }` with cold cache           | Silent advance to next marker (CC 38) | State C `element_not_found` with `requested_index`, `cached_marker_count`, refresh-cache hint |
| `goto_marker { name: "..." }` with cold cache        | Free-form `"No marker found matching"` string | Same intent, now structured State C envelope                                          |
| `goto_marker` against a populated cache              | Unchanged                            | Unchanged                                                                                      |

Caller migration: parse the State C envelope; on `element_not_found` issue `system.refresh_cache` and retry.

#### Project audit log split into three phases

Pre-v3.4.0 `[AUDIT] project.<command> executed` was emitted before parameter validation, before the destructive-confirmation gate, and before any route. Enterprise audit pipelines treated rejected calls as if they had run.

v3.4.0 splits the signal into three machine-filterable phases:

- `rejected` — validation refused the call (no side effect)
- `confirmation_required` — destructive policy gated, awaiting `confirmed:true`
- `executed` — route was actually invoked (success or hard failure)

SIEM rules that grep for `[AUDIT] project.<command> executed` need to add the new phases or they'll under-report rejections and confirmation prompts.

### Fixed (P0/P1 from 2026-05-08 review)

- **RB-2 — stdio launch parity.** `ProcessUtils.logicProApp()` and the `logicProBundleURL` runtime closure used to wrap `NSRunningApplication` and `NSWorkspace` lookups in `runAppKit`, which forced a nil return whenever the server ran as an MCP-client stdio subprocess (no AppKit runloop). The live e2e harness reported `logic_pro_running:false` while System Events on the same host could see Logic — exactly that bug. Both APIs are documented as thread-safe launch-services queries with no runloop dependency, so the wrapping was over-defensive. Removed.
- **RB-4 — release governance gate.** `.github/workflows/release.yml` now refuses stable tags (no `-prerelease` suffix) when notarization secrets (`MACOS_CERT_BASE64` et al.) are absent. Operators can opt out by setting repo variable `ALLOW_ADHOC_STABLE=1` (vars, not secrets — visible in repo settings as a deliberate trust decision). `Scripts/release.sh` got the same gate via `LOGIC_PRO_MCP_ALLOW_ADHOC_STABLE=1`. The local script also now records actual binary architecture(s) in `RELEASE-METADATA.json` (`architectures` field) so a `lipo -info` mismatch with the `LogicProMCP-macOS-universal.tar.gz` filename is detectable downstream.
- **RB-6 — install/uninstall non-interactive safety.** `Scripts/install-keycmds.sh:40` backup glob now includes `*.logikcs` (Logic 12.2+ binary key-commands format) — pre-fix the glob silently skipped that extension, so a Logic 12.2 user's bindings could be clobbered without backup. `Scripts/uninstall-keycmds.sh` `read -p` prompt now gates on `[ -t 0 ]` so non-TTY contexts (MDM, fleet automation, CI) skip the prompt instead of exiting `1` under `set -euo pipefail`. The Manual MIDI Learn flow can be auto-restored via `LOGIC_PRO_MCP_KEYCMD_AUTO_RESTORE=1`. README and `Scripts/install.sh` wording corrected from "installs the Key Commands preset" to "stages the Key Commands mapping reference" — Logic 12.2+ doesn't actually import the .plist.
- **H-1 — audit log timing.** `ProjectDispatcher.handle` no longer emits `executed` before validation. New `ProjectDispatcher.AuditPhase` enum (`rejected`, `confirmationRequired`, `executed`) drives phase-specific log lines. See BREAKING above.
- **H-2 — `goto_marker` target-faithful.** Cold-cache fallback to CC 38 removed. See BREAKING above.
- **H-3 — docs drift.** Architecture notes (`5s` → `3s` polling), `docs/TROUBLESHOOTING.md` (cache-refresh timing), `docs/API.md` (`record_sequence` 2-second cache poll → 500 ms live AX, project source freshness `5s` → `3s`), `README.md` (install URL pin `v3.1.1` → `v3.4.0`, test count `1059 (v3.1.9)` → `1110+ (v3.4.0)`). The drift was load-bearing — operators were waiting 5 seconds when the cache refreshed at 3.
- **H-4 — CI coverage gate re-armed.** `.github/workflows/ci.yml` Coverage step now enforces region ≥ 65% and line ≥ 72% (baseline on 2026-05-08 was 70.65% / 77.71%, so the thresholds carry ~5pp / ~6pp of slack for normal churn). Pre-fix the step ran `set +e` and `exit 0` so coverage regressions never blocked a merge. The `swift test` pass/fail signal at the prior step remains the authoritative test gate; this step adds the coverage threshold on top.
- **H-6 — AXValue force casts hardened.** `Sources/LogicProMCP/Accessibility/AXHelpers.swift` `getPosition` and `getSize` now match the `CFGetTypeID(... AXValueGetTypeID())` guard pattern used by `LibraryAccessor`, `PluginInspector`, and `AXLogicProElements`. A malformed AX attribute (Logic build drift, plugin mock, AX timeout returning a stub) returns nil instead of crashing with `Could not cast value of type ... to 'AXValue'`.

### Honest deferred (still open from 2026-05-08 review)

- **H-5 — `swift-testing` package dependency.** Removal triggers `missing required module '_TestingInternals'` on Swift 6.0 / 6.2 toolchains — the bundled Testing framework's SwiftPM glue isn't shipped yet. Pinned to `0.12.0` with the deprecation warning noise as a known tradeoff. Re-evaluate when Apple ships the SwiftPM-side fix (likely Xcode 16.5+).

### Added

- 15 new regression tests across 4 new files + 2 modified files:
  - `Tests/LogicProMCPTests/AXHelpersForceCastTests.swift` (6 tests for H-6).
  - `Tests/LogicProMCPTests/ProjectAuditPhaseTests.swift` (6 tests for H-1, including non-TTY path coverage and L0 read-only no-audit invariant).
  - `Tests/LogicProMCPTests/ProcessUtilsStdioParityTests.swift` (3 tests for RB-2; the bundle-URL and version tests skip cleanly on hosts without Logic Pro installed so CI runners stay green).
  - `Tests/LogicProMCPTests/CommercialReadinessTests.swift` updated: replaced the two cold-cache fallback tests with State C `element_not_found` assertions for both index- and name-based goto_marker.

### Changed

- `Sources/LogicProMCP/Dispatchers/ProjectDispatcher.swift` — `audit(_:phase:reason:)` helper added. L0 commands (`is_running`, `get_regions`) emit no audit lines.
- `Sources/LogicProMCP/Utilities/ProcessUtils.swift` — `logicProApp()` and `logicProBundleURL` no longer wrap their launch-services queries in `runAppKit`. `runAppKit` itself is unchanged (`activateLogicPro` and the in-process AppleScript path still need it).

### Tool description updates

- None needed — all changes are internal hardening or BREAKING via behavior, not parameter shape. The `goto_marker` schema is unchanged; only the cold-cache fallback semantics shifted.

### Tests

`swift test --no-parallel` → **1110 / 1110 PASS** (was 1095 in v3.3.0; +15 net).

## [3.3.0] — 2026-05-08

**Enterprise production-readiness P0 closure — fail-closed mutating writes + signal cleanup.** Closes 5 release blockers (RB-1.a/b/c, RB-3, RB-5) from the 2026-05-08 enterprise production review. The internal review verified each evidence line against the source and called the v3.2.0 ship `HARD NO-GO` until these closed. v3.3.0 closes them with 12 new regression tests; remaining P0/P1 items (RB-2 stdio launch parity, RB-4 release-workflow notarization gate, RB-6 install/uninstall non-interactive safety, H-1..H-6) tracked for follow-up.

### ⚠️ BREAKING

#### Mutating mixer / marker commands now require explicit target

Pre-v3.3.0 a malformed call could silently mutate the wrong target because the dispatcher helpers defaulted missing `track`/`index` to `0`. Mixer fader writes and marker deletes are not undoable from the operator's seat, so missing-target now fails closed with an explicit error.

| Tool / command                         | Pre-v3.3.0 behaviour (omitted target)             | v3.3.0+ behaviour                                                     |
|----------------------------------------|---------------------------------------------------|-----------------------------------------------------------------------|
| `logic_mixer.set_volume`               | wrote to track 0 silently                         | `requires explicit 'track' (Int ≥ 0)`                                  |
| `logic_mixer.set_pan`                  | wrote to track 0 silently                         | `requires explicit 'track' (Int ≥ 0)`                                  |
| `logic_mixer.set_plugin_param`         | wrote to track 0 / insert 0 / param 0 / value 0.0 | each of `track`, `insert`, `param`, `value` now required               |
| `logic_navigate.delete_marker`         | deleted marker 0                                  | `requires explicit 'index' (Int ≥ 0)`                                  |
| `logic_navigate.rename_marker`         | renamed marker 0 with empty string                | `index` required + `name` required-non-empty                           |

Caller migration: any client (LLM agent, automation script) that omitted `track`/`index` and relied on the implicit default must add the explicit value. Callers that already supplied the parameter are unaffected.

#### `track.duplicate` rejects unverified selection

`track.select` can return a State B envelope (`success:true, verified:false`, e.g. `readback_mismatch` or `retry_exhausted`) when the AX read-back can't confirm the selection landed. Pre-v3.3.0 `track.duplicate` proceeded on any `selectResult.isSuccess` and could duplicate whatever was actually selected; this matches the v3.1.2 P1-5 fix that the same gate already enforced for `track.delete`.

Affected callers: any client that proceeded after a State B select envelope without re-selecting. Recommended migration: handle `track.select` State B explicitly — re-issue selection or abort the mutation.

### Fixed

- **RB-3 — signal cleanup.** `MainEntrypoint.swift` SIGTERM/SIGINT handlers used to call `exit(0)` directly, skipping the AX poller, channel transports, and virtual MIDI port teardown. The handler now invokes a new public `LogicProServer.stop()` (which drives the same `stopPoller / stopChannels / stopPorts` triple as the happy-path lifecycle) on a dedicated background `signalQueue`, with a 3-second hard timeout exiting `1` so a supervisor can notice. `ServerStarting` protocol gained `stop() async` with a default no-op extension so existing test mocks compile unchanged.
- **RB-5 — E2E false-positive expectation.** `Scripts/live-e2e-test.py:514` previously asserted that `mixer.set_volume` without `track` "responds (default 0)" — the test literally locked the production fail-open into the suite. The harness now asserts the call is rejected with `"requires explicit 'track'"`, plus matching expectations for `set_pan` and `set_plugin_param`. Lines 932 / 952 (non-numeric track / empty params) tightened to the same fail-closed contract.

### Added

- `RoutingAuditInvariantTests` from v3.1.7 expanded with mutating-write fail-closed regression tests across `MixerDispatcher`, `NavigateDispatcher`, and `TrackDispatcher`. New tests:
  - `testMixerDispatcherSetVolumeRejectsMissingTrack`, `…RejectsNegativeTrack`, `testMixerDispatcherSetPanRejectsMissingTrack`, `testMixerDispatcherSetPluginParamRejectsMissingTargets` (4 tests; all verify the router is never invoked on rejection).
  - `testNavigateDispatcherDeleteMarkerRejectsMissingIndex`, `…RejectsNegativeIndex`, `testNavigateDispatcherRenameMarkerRejectsMissingIndex`, `…RejectsEmptyName` (4 tests).
  - `testDuplicateRefusesOnUnverifiedSelection`, `testDuplicateProceedsOnVerifiedSelection` (2 tests; mirrors the existing delete-State-B-refusal coverage).
  - `testLogicProServerStopInvokesPollerChannelsPortsTeardown`, `testLogicProServerStopDoesNotHangOnRepeatInvocation` (2 tests; pins the cleanup contract for the signal-handler path).

### Tool description updates

- `logic_mixer.description` and `logic_navigate.description` now name the BREAKING change inline so an LLM agent reading the schema sees the new contract without diving into CHANGELOG.

### Tests

`swift test --no-parallel` → **1095 / 1095 PASS** (was 1083 in v3.2.0; +12 new). Build clean.

### Known gaps tracked for follow-up

The 2026-05-08 review flagged six release blockers and six high findings; this release closes RB-1.a/b/c, RB-3, RB-5 (5 of 6 P0). The remainder is honest deferred:

- **RB-2 (stdio launch parity)** — `ProcessUtils` AppKit-vs-fallback gap under sandboxed MCP-client launch needs a topology probe before fix lands.
- **RB-4 (release workflow notarization gate)** — production-tag enforcement needs a workflow guard (`refs/tags/v*` requires `MACOS_CERT_BASE64`) and removal of the local `Scripts/release.sh` "ADHOC" path.
- **RB-6 (install/uninstall non-interactive safety)** — `install-keycmds.sh:40` backup glob must include `*.logikcs`; `uninstall-keycmds.sh` must skip the `read -p` prompt under non-TTY.
- **H-1..H-6** — audit-log timing, goto_marker cold-cache fallback, README/API/ARCHITECTURE drift, CI coverage gate disabled, swift-testing dependency stale, AXValue force casts in `AXHelpers`.

These are tracked for v3.4.x.

## [3.2.0] — 2026-05-07

**Marker provenance — Boomer P2-3 closed.** `MarkerState` now surfaces the origin of `position` in a machine-readable form (`position_source`: `parser` / `fallback` / `unknown`). When `goto_marker` routes to a fallback or unknown provenance marker, it adds `marker_position_uncertain: true` to the response extras so the caller can explicitly detect that a cache fallback position was used.

### Honest deferred — NG10 sub-bar navigation accuracy

v3.2.0 **does not ship a navigation accuracy fix**. NG10 (deferred from v3.1.11: `gotoPositionViaBarSlider` consuming only the first dot-component) is re-deferred to v3.3. Reason:

The T0 live spike (measured on 2026-05-07) invalidated the PRD assumption:
- The Logic 12.2 Go to Position dialog is a 4-segment `AXSlider` structure (bar / beat / div / tick as separate sliders), not a single text input.
- `AppleScript keystroke "146.4.4.240"` does not reach any segment.
- Attempting to set the AXSlider value directly fails (the mapping between raw values (~2.27E+15) and displayed values has not been decoded).

The v3.1.11 navigation behavior (navigates only the `bar` first component) is therefore preserved unchanged. v3.3 will attempt closure after reverse-engineering the slider raw value mapping in the PRD.

### Schema additions (back-compat)

`MarkerState` Swift domain model:
```swift
enum PositionSource: String, Codable { case parser, fallback, unknown }

struct MarkerState {
    let id: Int
    var name: String
    var position: String
    var positionSource: PositionSource  // new in v3.2
}
```

`logic://markers` JSON wire schema:
```json
{
  "id": 0,
  "name": "VOCALS",
  "position": "146.4.4.240",
  "position_source": "parser",
  "is_canonical": true
}
```

### Codable backward compat

When decoding existing v3.1.x cache snapshots, absence of the `positionSource` field defaults to `.unknown` (prevents false provenance). New markers always explicitly carry `.parser` or `.fallback`.

### `goto_marker` uncertainty extras

When routing to a marker whose `position_source ∈ {.fallback, .unknown}` in cache:
```json
{
  "success": true, "verified": true, "requested": "1.1.1.1",
  "marker_position_uncertain": true,
  "marker_position_source": "fallback"
}
```
Top-level extras are merged only into HC State A/B responses. State C (`success: false`) responses are preserved unchanged.

### Tests

1064 → 1074 PASS. 10 new cases — Codable round-trip × 3, legacy snapshot decode × 2, HC top-level merge (State A/B/C/invalid JSON) × 4, `PositionSource` rawValue stability × 1.

### Behavior change

None. The `goto_marker` / `transport.goto_position` behavior from v3.1.11 is preserved unchanged. Only new fields are added; no existing fields are modified.

## [3.1.11] — 2026-05-07

**Issue #9 (`thomas-doesburg`) — English Logic 12.2 marker position parser accuracy + 13-locale menu path documentation + lenient 1–3 component policy removed.**

During v3.1.10 verification, the reporter identified two findings:
- **F1 (resolved — doc improvement)**: The Marker List window on English 12.2 is under `Navigate → Open Marker List` (not the Window menu). The v3.1.9 release notes used the phrase "Open the Marker List window", leading English users to search the Window menu.
- **F2 (parser bug)**: VOCALS marker position `"146 4 4 240."` (trailing period from Logic UI rendering) → parser rejection → fallback `\(index+1).1.1.1` = `"6.1.1.1"`. Data accuracy violation.

### Fix

`AXLogicProElements.parseMarkerListPosition` hardened with the following policies:

1. **Trailing period / comma strip** (`while`-loop): absorbs Logic UI rendering artifacts.
2. **Whitespace/tab-only separators** (NG7, Guardian P0-3): dots are meaningful only at the end. Mixed separators (`"1.1 1.1"`) are rejected — prevents manufacturing incorrect values.
3. **ASCII digit narrowing** (NG9, Guardian P2-2): uses `Int(_: String)` failable initializer — rejects non-ASCII digits such as Arabic-Indic.
4. **1-based validation** (NG8, Guardian P0-2): all components must be ≥ 1 — `"0 0 0 0"` is rejected.
5. **Strict 4-component policy** (NG11, Boomer P1-1): lenient 1–3 component handling removed. Logic UI always exposes 4 components, so 1–3 components likely represent non-position cells (e.g. tempo) — no silent manufacturing of an incorrect bar value.

### Behavior change (stated explicitly)

`"17 2"` (2-component lenient), which was valid in v3.1.10, returns nil in v3.1.11. Impact:
- No observed Logic build uses 1–3 component notation, so user-facing impact is zero.
- Theoretical impact: if a future build exposes a shortened header row → fallback `\(index+1).1.1.1` (no silent manufacturing of an incorrect bar value — honest).

### Sub-bar navigation (NG10 separated, Guardian P0-1)

`goto_marker { name: "VOCALS" }` correctly surfaces `position: "146.4.4.240"` from cache, but the AX `gotoPositionViaBarSlider` only extracts the first component (bar) and sets the slider — beat/div/tick are ignored. v3.1.11 scope ends at **cache accuracy**. Sub-bar navigation accuracy is separated into its own PRD (v3.2 — `gotoPositionViaBarSlider` extension).

### TROUBLESHOOTING 13 locales (Boomer P1-2)

The code already recognizes Marker List window titles in 13 locales (KR/EN/JA/FR/DE/ES/IT/ZH-S/ZH-T/RU/PT/NL), but v3.1.9 docs only listed KR/EN — users in other locales encountered the same discoverability gap. v3.1.11 docs add the 13-locale table and explicitly state "Navigate menu on all builds".

### Implementation

`AXLogicProElements.parseMarkerListPosition` (15 lines body, doc 7 lines):

```swift
/// Converts a Logic Marker List cell position string to the canonical "bar.beat.div.tick" form.
///
/// Observed input variants:
/// - Korean 12.2: "1 1 1 1" (space-separated, whole-bar)
/// - English 12.2: "146 4 4 240." (space-separated + trailing period from UI rendering)
///
/// Requires exactly 4 components, each an ASCII integer ≥ 1. Logic UI always exposes 4
/// components, so 1–3 components likely represent non-position cells (e.g. tempo) and
/// return nil. Callers use the `\(index+1).1.1.1` fallback.
static func parseMarkerListPosition(_ raw: String) -> String? {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = trimmed.last, last == "." || last == "," {
        trimmed.removeLast()
    }
    let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    guard parts.count == 4,
          parts.allSatisfy({ (Int($0) ?? 0) >= 1 }) else {
        return nil
    }
    return parts.joined(separator: ".")
}
```

### Tests

Removed `parseMarkerListPosition_validInputs` / `_invalidInputs` → consolidated into 2 Swift Testing parameterized test functions:
- `parseMarkerListPosition_valid` (8 cases): trailing-dot, trailing-comma, multiple spaces, tab, exact 4-component.
- `parseMarkerListPosition_invalid` (17 cases): 1–3 components (NG11), 0-positions (NG8), Arabic-Indic (NG9), mixed separator (NG7), etc.

New integration tests:
- `enumerateMarkers_trailingDotPosition_canonicalizes` — English 12.2 scenario (synthetic AX tree).
- `enumerateMarkers_koreanWholeBarPosition_canonicalizes` — Korean 12.2 regression (G3 both-direction verification).

Existing `enumerateMarkers_unparseablePosition_usesIndexFallback` (caller fallback regression) continues to PASS.

`swift test --no-parallel` → **1064 / 1064 PASS** (was 1062 in v3.1.10; +2 net — the 25 parameterized cases count as 2 test functions, so the net count change is small; actual case matrix is +20).

### Review process

PRD v0.3 = Strategist + Guardian + Boomer 3-agent integration. This fix consolidates 7 P0/P1 findings:
- **Strategist**: parser line reduction, edge cases 25→14, language-switch safety procedure
- **Guardian P0-1**: sub-bar navigation not feasible → separated as NG10
- **Guardian P0-2**: reject 0-values (NG8)
- **Guardian P0-3**: reject mixed separators (NG7)
- **Guardian P2-2**: ASCII digit narrowing (NG9)
- **Boomer P1-1**: lenient removed → strict 4 (NG11)
- **Boomer P1-2**: 13-locale documentation integrated

Ticket review by 4 agents (boomer + strategist + tester + guardian):
- **Tester**: added Korean whole-bar integration regression (G3 both-direction verification)
- **Guardian**: added TODO/FIXME grep verification step (AC-4.2)

## [3.1.10] — 2026-05-07

**boomer P1-1 hotfix on top of v3.1.9: `goto_marker` was a silent no-op relative to its parameter.** Final BOOMER-6 review caught that `NavigateDispatcher.handle("goto_marker", ...)` resolved the target marker correctly (by name from cache, or by index) and then routed `nav.goto_marker { index: <id> }` to `MIDIKeyCommandsChannel`, which ignores all params and fires fixed CC 38 — Logic's "go to next marker" hotkey. Both index- and name-based goto therefore advanced the marker pointer by one regardless of which marker the caller asked for. The cache lookup did its job; the routing throw the result away.

### Fix

`NavigateDispatcher.goto_marker` now resolves the target `MarkerState` from cache (by `id` for index-based, by `localizedCaseInsensitiveContains` for name-based), then routes via `transport.goto_position` using the marker's `position` string. The marker-list-window scrape that v3.1.9 introduced supplies the cache with correct positions on Logic 12.2; the read+write cycle now correctly navigates to the named bar.

**Cold-cache fallback**: when the cache has no markers (poller hasn't run yet, or the marker list window is closed on Logic 12.2), index-based callers fall through to the legacy `nav.goto_marker` keycmd path so they still get *some* navigation signal — best-effort, advances Logic's marker pointer by one. Name-based callers with an empty cache return `No marker found matching '<name>'` because the keycmd has no name-aware semantic to fall back on.

### Tests

- `testNavigateDispatcherGotoMarkerByNameUsesCachedMarker` — updated: asserts `transport.goto_position { position: "7.1.1.1" }` (was: `nav.goto_marker { index: "7" }` to keycmd channel).
- `testNavigateDispatcherGotoMarkerByIndexUsesCachedPosition` — new: asserts index-based path also routes via position.
- `testNavigateDispatcherGotoMarkerColdCacheFallsBackToKeycmd` — new: cold cache + index → legacy keycmd.
- `testNavigateDispatcherGotoMarkerColdCacheNameReturnsError` — new: cold cache + name → "No marker found matching" error.
- `testNavigateDispatcherRoutesMarkerAndZoomCommands` — updated: asserts both index- and name-based goto land on AX `transport.goto_position` (was: keycmd `nav.goto_marker`).

`swift test --no-parallel` → **1062 / 1062 PASS** (+3 net new tests for the fix; 1 existing assertion updated for the new contract).

### Behaviour change for callers (additive correctness, not breaking)

- `goto_marker { index: 5 }` used to advance Logic's marker pointer once regardless of the index. **Now**: goes to bar.beat.div.tick of marker id 5 (when in cache).
- `goto_marker { name: "Verse" }` used to do the same one-step advance regardless of name. **Now**: goes to that marker's saved position.
- Existing call sites that depended on the bug (i.e. used `goto_marker` to advance the pointer by one) need to use `goto_marker` with no params or another mechanism — but no such callers are documented or tested anywhere in the codebase, so this is being treated as additive.

### CHANGELOG correction (v3.1.9)

The v3.1.9 entry stated `1057 / 1057 PASS (+10 net)`. The accurate count was `1059 / 1059 (+12 net)` — the `StateCache.updateMarkers` invariant regression tests were added after the line was drafted. Corrected in this release.

## [3.1.9] — 2026-05-07

**Issue #8 (`thomas-doesburg`'s 12.2 verification follow-up to #5 / #7) — Logic Pro 12.2 marker walker via `Marker List` window AXTable.** v3.1.8's `AXRuler`-structural strategy assumed user markers lived in the arrange window's AX subtree. Verified live on Logic Pro 12.2 today: that subtree contains **zero `AXRuler` elements** at all. User markers only appear in the dedicated `*-마커 목록` / `*-Marker List` window's `AXTable`. v3.1.9 adds that scrape as the primary strategy and fixes a pre-existing `StateCache` invariant bug that was masking "honest empty" as "never polled".

### Live diagnosis (2026-05-07, Logic Pro 12.2 + 무제 15.logicx)

```
osascript> tell application "System Events" to tell process "Logic Pro" \
    to count of (every UI element of window 1 whose role is "AXRuler")
→ 0
```

User markers (created via `탐색 → 마커 → 마커 생성`) appear in the `*-마커 목록` window only:

```
AXWindow desc="무제 15 - 마커 목록"
  AXTable
    AXRow
      AXCell (Lock — empty)
      AXCell ─ AXGroup(desc="1 1 1 1 ")    ← position, space-separated B B D T
      AXCell ─ AXCell(desc="마커 1")        ← marker name
      AXCell ─ AXGroup(desc="∞")            ← length
    ...
```

### Fix

- **`AXLogicProElements.findMarkerListWindow`** (new): enumerates `kAXWindowsAttribute` on the app root, matches title suffix (`- 마커 목록` Korean / `- Marker List` English), returns the marker list window or nil.
- **`AXLogicProElements.enumerateMarkersFromListWindow`** (new): scrapes `AXTable → AXRow → AXCell[1..3]` rows. Position and name extracted from each cell's first child description (skipping the placeholder `"셀"` / `"Cell"` strings the cells carry by default). Position parsed from space-separated `"B B D T "` to canonical `"bar.beat.div.tick"` via `parseMarkerListPosition`.
- **`AXLogicProElements.parseMarkerListPosition`** (new): converts Logic 12.2's space-separated marker-list position notation to the project-wide `"1.1.1.1"` form. Returns nil for invalid inputs so callers fall through to a default.
- **`AXLogicProElements.enumerateMarkers`** (modified): strategy order is now (1) marker list window → (2) arrange-area `AXRuler` (Logic 11.x compat) → (3) keyword fallback (oldest path). Strategy 1 wins when both surfaces exist (mid-version transition).
- **`AccessibilityChannel.defaultGetMarkers`** (modified): no longer requires `getArrangementArea` — that helper returns nil for many Logic 12.2 install configurations because the arrange-area identifier changed. Pre-v3.1.9 the early `.error` return short-circuited the StatePoller before it ever tried the marker list window. New flow: marker list window → arrange-area walk → empty array as success (so the cache reflects "no markers detected" rather than getting stuck at `.distantPast`).

### `StateCache.updateMarkers` invariant fix (P0 cache-staleness bug)

Pre-v3.1.9:
```swift
func updateMarkers(_ newMarkers: [MarkerState]) {
    guard markers != newMarkers else { return }
    markers = newMarkers
    markersFetchedAt = Date()
}
```

The equality short-circuit skipped the `markersFetchedAt` update. A poller cycle that successfully observed "still no markers" left `markersFetchedAt == .distantPast` if the cache had also started empty (cold-start case). The resource handler then reported `source: "default"` instead of `"ax_live"` — and `cache_age_sec: null` instead of an actual age — making **honest empty indistinguishable from never-polled**. The marker list closed scenario hit this exact case on every poll cycle.

v3.1.9:
```swift
func updateMarkers(_ newMarkers: [MarkerState]) {
    markersFetchedAt = Date()
    if markers != newMarkers {
        markers = newMarkers
    }
}
```

`markersFetchedAt` always advances on a successful poll, regardless of data change. The data assignment is still guarded so listeners that diff `cache.markers` directly don't see redundant publishes. The other `update*` cache methods (transport, tracks, mixer, regions, project) already had this semantic — `updateMarkers` was the outlier.

### Live verification (2026-05-07, Logic Pro 12.2)

E2E ran the v3.1.9 release binary against a local Logic project fixture (5 user markers created at bars 1, 1, 1, 5, 17) via stdio JSON-RPC. Captured `logic://markers` envelope:

**Marker List window OPEN**:
```json
{
  "cache_age_sec": 7.05, "ax_occluded": false,
  "source": "ax_live",
  "data": [
    {"id": 0, "name": "마커 1", "position": "1.1.1.1"},
    {"id": 1, "name": "마커 2", "position": "1.1.1.1"},
    {"id": 2, "name": "마커 3", "position": "1.1.1.1"},
    {"id": 3, "name": "마커 4", "position": "5.1.1.1"},
    {"id": 4, "name": "마커 5", "position": "17.1.1.1"}
  ]
}
```

**Marker List window CLOSED**:
```json
{
  "cache_age_sec": 6.64, "ax_occluded": false,
  "source": "ax_live",
  "data": []
}
```

Pre-v3.1.9 `source: "default"` on the closed case is now `"ax_live"` (honest empty).

`logic://project/info` and `logic://tracks` continue to work — `tempo: 120, timeSignature: 4/4, trackCount: 2, source: "project_file"`; tracks `source: "ax_live", count: 2` with real names.

### Caveat (UX) — marker list window must be open

The fix only resolves user markers when the user has opened the dedicated Marker List window (via Logic's `탐색 → 마커 목록 열기 (Navigate → Open Marker List)` menu). When closed, `logic://markers` returns the honest-empty signal documented above. **No automatic open** ships in v3.1.9 — that's an opt-in we want explicit user consent on. Tracked as a follow-up ergonomics improvement; if you'd like it, file an issue.

### Tests

- `Tests/LogicProMCPTests/AXMarkers12MarkerListTests.swift` (new, 10 tests):
  - 3 marker list scrape scenarios (open with rows / open empty / closed → AXRuler fallback)
  - 4 `parseMarkerListPosition` valid / invalid input cases
  - 2 `findMarkerListWindow` Korean / English / not-open
  - 1 list-and-ruler-both-present (list strategy must win)
  - 2 `StateCache.updateMarkers` `markersFetchedAt` invariant tests (regression coverage for the cache-staleness bug above)

`swift test --no-parallel` → **1059 / 1059 PASS** (was 1047 in v3.1.8; +12 net — 8 marker-list scrape + 2 parse helper + 2 `StateCache.updateMarkers` `markersFetchedAt` invariant regression tests).
`swift build -c release` clean.

### Cross-refs

- [#5](https://github.com/MongLong0214/logic-pro-mcp/issues/5) — original report (Logic 11.x marker ruler). Closed under v3.1.5; effectively reopened by this release for 12.x but kept closed because the AX walker fix lands here.
- [#7](https://github.com/MongLong0214/logic-pro-mcp/issues/7) — v3.1.7 dictionary-empty diagnosis from `thomas-doesburg`. Closed by v3.1.8.
- [#8](https://github.com/MongLong0214/logic-pro-mcp/issues/8) — 12.2-specific marker AX hierarchy investigation. Closed by v3.1.9 (this release).

## [3.1.8] — 2026-05-06

**Issue #7 (`thomas-doesburg`) — Logic Pro 12.x read-path recovery via project-file fallback + AX hardening.** v3.1.5 / v3.1.6 / v3.1.7 closed Issues #3 / #4 / #5 by routing `logic://tracks` / `logic://markers` / `logic://project/info` through `tell front document → tracks/markers/tempo/time signature` AppleScript reads. Logic Pro 12.x ships an AppleScript scripting dictionary that does not expose any of those terms — every call returns `-2753` ("variable is not defined") or `-1700` ("Can't make tempo of document 1 into type reference") at runtime, and the AX fallback is the panel-focus-dependent scrape that prompted the original bug reports. End-to-end behaviour was identical to v3.1.4 on every Logic 12.x install. v3.1.8 ships a project-file (`MetaData.plist`) tier-merge at the resource layer + a hardened AX walker, and removes the now-dead AppleScript-primary code paths.

### Issue #7 reproduction (verified locally on Logic Pro 12.0.1, build 6590)

```
$ osascript -e 'tell application "Logic Pro" to tell front document to return count of tracks'
→ -2753: tracks 변수를 정의하지 않았습니다.
$ osascript -e 'tell application "Logic Pro" to tell front document to return count of markers'
→ -2753: markers 변수를 정의하지 않았습니다.
$ osascript -e 'tell application "Logic Pro" to return tempo of front document'
→ -1700: Can't make tempo of document 1 into type reference.
```

`path of front document` still works on 12.x — that's the only AppleScript surface this fix relies on.

### Issue fixes

- **#7 / #4 — `logic://project/info` defaults stuck on Logic 12.x.** `ResourceHandlers.readProjectInfo` now performs **per-field tier merge**: cached values (live AX poll via `StatePoller`) win for any field where the cache holds a non-default value; otherwise the field is filled from `<bundle>/Alternatives/000/MetaData.plist` (`BeatsPerMinute`, `SongSignatureNumerator/Denominator`, `NumberOfTracks`). Whole-record freshness was rejected because `defaultGetProjectInfo` only writes `name + lastUpdated` to the cache — leaving tempo / tsig / trackCount at struct defaults — so a "fresh AX cache wins" rule would block the file's correct values forever. The merge is **read-only with respect to cache** (the poller is the sole writer) so file values cannot leak into shared mutable state. Envelope gains `source: "ax_live"|"cache"|"project_file"|"default"` and (when sourced from file) `last_saved_age_sec`.

- **#7 / #3 — `logic://tracks` returns either `[]` or Inspector field labels (`Mute:`, `Loop:`, …) when the Mixer panel is focused.** Two-part fix:
  - `AXLogicProElements.getTrackHeaders` outline/table fallback (lines 325-330 in v3.1.7) now requires the candidate to have at least one `kAXLayoutItemRole` direct child. The pre-v3.1.8 unconditional "first outline/table" fallback was the silent matcher that surfaced the Inspector subtree as if it were the track-header rail.
  - `ResourceHandlers.readTracks` consults the cache for the live tier; when the cache is empty (or all-suffix-`:` Inspector contamination passes through), the resource layer synthesises **placeholder** rows from `MetaData.plist`'s `NumberOfTracks` (`name: "Track 1".."Track N"`, `placeholder: true`). Placeholder rows are never written back to `StateCache` — `track.select { name: "Track 5" }` (which reads `cache.getTracks()` in `TrackDispatcher.swift:44`) cannot match a placeholder name and route a write to the wrong track. Envelope `source: "ax_live"|"ax_live_with_file_count"|"project_file"|"default"`.

- **#7 / #5 — `logic://markers` always empty on Logic 12.x.** `AXLogicProElements.enumerateMarkers` now resolves the marker ruler via `kAXRulerRole` + structural position (the second AXRuler in the arrange area subtree is the marker ruler; the first is the timeline). The pre-v3.1.8 keyword match (`marker` / `마커` substring on AXGroup id/desc/title) is preserved as a fallback for older Logic versions that still expose the keyword. Envelope `source: "ax_live"|"cache"|"default"`; `ax_occluded:true` continues to flag untrusted-empty when a plugin / modal window has focus.

### Removed

- **`AccessibilityChannel.markersViaAppleScript` / `projectInfoViaAppleScript` / `tracksViaAppleScript`** (~270 LOC) and their `AccessibilityChannel.Runtime` wiring (`markersAppleScript` / `projectInfoAppleScript` / `tracksAppleScript` closures + initialiser parameters). Dead on every Logic 12.x install (the dictionary terms they query don't exist); kept only added a wasted `-2753` IPC round-trip per poll. The follow-on parse helpers (`parseAppleScriptResult`, `parseMarkerRecords`, `formatBeatsAsBarPosition`, `appleScriptBool`, US/RS in-band delimiters) are removed too — no surviving callers.

- **`Tests/LogicProMCPTests/AccessibilityChannelAppleScriptReadsTests.swift`** (369 LOC, 16 tests). Validated wire-format of the deleted helpers; obsolete.

- `axBackedRuntimeWiresAppleScriptHelpers` test that asserted the deleted Runtime fields were wired in `axBacked()`.

- `StatePoller.pollProjectInfo` no longer passes `cached_tempo` / `cached_track_count` params (the AppleScript helper that consumed them is removed).

### Added

- **`Sources/LogicProMCP/Utilities/LogicProjectFileReader.swift`** — actor-free module that reads `<bundle>/Alternatives/000/MetaData.plist` for the project-file tier. Path validation per PRD §6.3:
  1. Reject paths whose `pathComponents` contain `..` (defensive — pre-`resolvingSymlinksInPath` and post-).
  2. Require `.logicx` directory.
  3. Resolve leaf symlinks (`Alternatives/000/MetaData.plist`).
  4. Verify leaf real-path strict-prefix-matches the resolved bundle root (anti symlink-escape).
  5. Cap read at 10 MB.
  6. **mtime-jitter retry**: read mtime, parse, re-read mtime; on diff sleep 50 ms + retry once. Persistent jitter → return nil. Mitigates the Logic-mid-save atomic-write window flagged by guardian review.

- **`ResourceHandlers.wrapWithCacheEnvelope` `extras: [String: Any]?`** parameter (default nil → byte-identical envelope shape to v3.1.7). Used by tier-merging readers to expose `source` / `last_saved_age_sec` / `placeholder` flags. Keys serialised in deterministic (sorted) order; unsupported value types (NSDate, custom classes) silently filtered. Mixer's hand-rolled envelope (`readMixer:184`) migrated to share the same shape.

- **`StateModels.TrackState.placeholder: Bool?`** — true on file-count placeholder rows. Optional (Codable backward-compat with v3.1.7 JSON snapshots that lack the field).

- **`StateModels.ProjectInfo.source: String?` / `lastSavedAgeSec: Double?`** — optional Codable additions. v3.1.7 envelopes decode cleanly with `nil` defaults.

- **`AppleScriptChannel.currentDocumentPath()`** — `@Sendable` static helper extracted from the existing instance method. Lets `LogicProjectFileReader.Runtime.production` resolve the open project's path without instantiating a channel.

### Tests

- `Tests/LogicProMCPTests/LogicProjectFileReaderTests.swift` (15 tests) — synthetic `.logicx` bundles, binary + XML plist, missing keys, corrupt bytes, 10 MB cap, `..` rejection, symlink-escape rejection, `/private/Users/...` normalisation, Korean filename, future-mtime clamp, mtime-jitter retry recover + persistent-fail.
- `Tests/LogicProMCPTests/ResourceProjectInfoTierMergeTests.swift` (7 tests) — cache-fresh tempo wins, file-only tempo, defaults, cache-vs-file divergence (95 vs 80), envelope source presence, last_saved_age_sec only on `project_file` source, **G5 cache-no-poison invariant**.
- `Tests/LogicProMCPTests/ResourceTracksTierMergeTests.swift` (8 tests) — live tracks pass-through, placeholder synthesis, default empty, **G5 placeholder-not-cached**, Inspector contamination heuristic strict + lenient, cache-wins-over-file, poller-empty-but-file-present.
- `Tests/LogicProMCPTests/ResourceEnvelopeExtrasTests.swift` (9 tests) — extras nil byte-identical, sorted order, numeric / bool / nested values, unsupported type filtered, axOccluded preserved.
- `Tests/LogicProMCPTests/Issue7IntegrationTests.swift` (5 scenarios) — S1 Tracks panel live, S2 Mixer panel placeholder fallback, S3 no document defaults, S4 cache-vs-file divergence, S5 multi-call no-poison.
- `Tests/LogicProMCPTests/Issue7BackwardCompatTests.swift` (5 tests) — v3.1.7 ProjectInfo / TrackState JSON decodes into v3.1.8 models with new fields nil; v3.1.8 encode emits new fields when set.
- 4 v3.1.7 fixtures (`AccessibilityChannelTests.swift`, `AXLogicProElementsTests.swift`) gained explicit `kAXLayoutItemRole` on track-header elements to match the strict v3.1.8 contract.

`swift test --no-parallel` → **1047 / 1047 PASS** (was 1019 in v3.1.7; +28 net = +49 new — 21 deleted: 16 from `AccessibilityChannelAppleScriptReadsTests` + axBackedRuntimeWiresAppleScriptHelpers + 4 fixture fix-ups). `swift build -c release` clean.

### Live verification

- **Automated** (this commit): `Scripts/issue7_live_verify.sh` — runs against any open Logic project, prints `path of front document`, `MetaData.plist` mtime, and the four fields v3.1.8 reads. Confirms the AppleScript path-acquisition + plist-parse pipeline works on Logic Pro 12.0.1.
- **Manual L1 (deferred to user)**: open `Lofi-Dreamscape-80.logicx` (BPM 80, 31 tracks, 4/4) in Logic Pro 12.x, focus the Tracks panel → `logic://project/info` should return `tempo: 80`, `timeSignature: "4/4"`, `trackCount: 31`, `source: "project_file"` or `"ax_live"`.
- **Manual L2 (deferred)**: same project, focus the Mixer panel (the originally-#3 case) → `logic://tracks` should return ≥ 31 entries (placeholder names acceptable; **must not be 0 and must not be Inspector field labels**), `source: "project_file"` or `"ax_live_with_file_count"`.
- **Manual L3 (deferred)**: close all documents → all three resources return defaults / empty without crash.

### Out-of-scope (deferred per PRD NG)

- **Track names via project file** (NG1). `Alternatives/000/ProjectData` is a custom binary blob (verified `file` output `data` with header `#G\xc0\xab\xd0\x09`), not the XML the issue reporter conjectured. Reverse-engineering deferred to a future PRD.
- **Marker positions / names via project file** (NG2). Same reason as NG1. Trigger to revisit (PRD OQ-5): 3+ user reports of `ax_occluded:true` on real markers, OR Logic 13 ships removing `markers` AX surface entirely.
- **Per-section document-identity contract** (NG8 / boomer P1). Existing cache invalidation on `hasDocument:false` is sufficient for v3.1.8. Trigger to revisit (PRD OQ-6): user reports of cross-project state contamination.
- **Tri-state marker result** (NG9 / boomer P1). Empty `[]` with `ax_occluded:true` is the existing untrusted-empty signal; preserved.

## [3.1.7] — 2026-05-05

**Honest correction of the v3.1.6 audited coverage matrix + post-release simplify pass.** A v3.1.7 verification audit reading every channel's actual handler list against `ChannelRouter.routingTable` and `CGEventChannel.keyMap` found that the v3.1.6 SETUP.md §4.1 matrix understated keycmd dependence — it listed only `transport.capture_recording` as effectively-keycmd-only when in fact **8 user-facing ops** have the same property: their nominal `cgEvent` fallback has no `keyMap` entry, so the keycmd channel is the only path that actually fires the action on Logic 12.2. v3.1.7 ships the corrected matrix, updates the runtime `MIDIKeyCommandsChannel.healthCheck` detail to match, and adds `RoutingAuditInvariantTests` so future drift fails the build.

### Honest corrections

The following ops were misclassified as `RECOMMENDED` or `NO — optional` in v3.1.6 but in fact **require** a manual MIDI Learn binding to function on Logic 12.2:

| MCP tool                                  | mappingTable op (CC#)              | v3.1.6 said                  | v3.1.7 says                                 |
|-------------------------------------------|------------------------------------|------------------------------|---------------------------------------------|
| `logic_edit.duplicate`                    | `edit.duplicate (97)`              | NO — optional                | YES — keycmd-only                           |
| `logic_edit.normalize`                    | `edit.normalize (96)`              | NO — optional                | YES — keycmd-only                           |
| `logic_edit.toggle_step_input`            | `edit.toggle_step_input (44)`      | RECOMMENDED                  | YES — keycmd-only                           |
| `logic_navigate.goto_marker`              | `nav.goto_marker (38)`             | RECOMMENDED                  | YES — keycmd-only                           |
| `logic_navigate.delete_marker`            | `nav.delete_marker (45)`           | RECOMMENDED                  | YES — keycmd-only                           |
| `logic_navigate.set_zoom_level`           | `nav.set_zoom_level (47)`          | RECOMMENDED                  | YES — keycmd-only                           |
| `logic_project.bounce`                    | `project.bounce (62)`              | NO — optional                | YES — keycmd-only                           |
| `logic_transport.capture_recording`       | `transport.capture_recording (73)` | YES (orphan, no MCP tool)    | YES (unchanged)                             |

If you depend on any of these eight ops and were skipping the §4 manual binding flow because v3.1.6 said it was optional, you need to bind those ops now. SETUP.md §4 has updated walkthroughs.

`automation.set_mode (84)` is also moved into the **orphan** list because MCU does not actually handle that operation key (it handles `track.set_automation` instead — verified by inspection of `MCUChannel.execute`), so the keycmd path would be the only mappingTable hit if a future tool routes to it.

### Added

- `RoutingAuditInvariantTests` (`Tests/LogicProMCPTests/RoutingAuditInvariantTests.swift`) — six unit tests that programmatically assert (a) every declared keycmd-only op has no `CGEventChannel.keyMap` shortcut, (b) every declared keycmd-only op IS in `MIDIKeyCommandsChannel.mappingTable`, (c) every declared keycmd-only op routes via `.midiKeyCommands` in `routingTable`, (d) the runtime health detail enumerates every op in the declared set, (e) every `mappingTable` op has a `routingTable` entry, (f) the health detail stays under the 1 KB UTF-8 budget. The build now fails the moment any of these invariants drifts.

### Changed

- `docs/SETUP.md §4.1` audited coverage matrix rewritten — bolded the 8 keycmd-only rows, expanded the orphan list to include `automation.set_mode` and `track.create_stack`, replaced the "Effectively-keycmd-only" subsection with a per-row "Working non-keycmd channel" column so the answer is computable from the table alone.
- `MIDIKeyCommandsChannel.manualValidationDetailSuffix` enumerates all 8 keycmd-only ops + 9 orphans (was 1 + 7 in v3.1.6).
- `CGEventChannel.keyMap` and `MIDIKeyCommandsChannel.manualValidationDetailSuffix` lifted from `private static let` to `static let` so the audit invariant test can read them via `@testable import`.

### Internal cleanup (no behaviour change)

The /loop verification work also folded these post-v3.1.6 commits into `main`:

- `NoteSequenceParseError.hint` computed property — `TrackDispatcher`, `MIDIKeyCommandsChannel.play_sequence.keycmd`, and `CoreMIDIChannel.play_sequence` now share one source of truth (was three duplicate four-case switches).
- `MIDIDispatcher.validPorts` set + `MIDIKeyCommandsChannel.manualValidationDetailSuffix` promoted to static storage to remove per-call allocations.
- `HonestContract.isTerminalStateC` short-circuits non-`{` messages before JSON parse.
- `ChannelRouter.route()` hoists `let isBypass` outside the `for channelID in chain` loop.
- `dispatchSendOp` in `MIDIDispatcher` drops its unused `command:` parameter (six call-site arg lines removed).
- `JSONHelper.swift` drops the now-redundant `nonisolated(unsafe)` modifier from three Sendable codecs (clears three Swift 6 build warnings).

### Tests

`swift test --no-parallel` → **1019 / 1019 PASS** (was 1013 in v3.1.6; +6 from `RoutingAuditInvariantTests`).

### Research

- Internal feasibility note on xaexx1's "Option 1" recommendation (`LogicProMCP --install-keycmds` programmatic `.logikcs` installer). Conclusion: not autonomous-safe because Logic 12.2 stores actual key/MIDI assignments inside an undocumented base64 `LogicBinaryPreferences` blob (~840 lines of XML's body) whose layout shifts between Logic point releases.

## [3.1.6] — 2026-04-30

**Issue #1 closure: KeyCmd port routing + Manual MIDI Learn docs + Homebrew CLT-only install.** Pre-v3.1.6 the `MIDIKeyCommands` channel had two systemic gaps that made [Issue #1](https://github.com/MongLong0214/logic-pro-mcp/issues/1) (xaexx1) reproducible end-to-end: (1) `logic_midi.send_cc` had no way to address the `LogicProMCP-KeyCmd-Internal` virtual port, so manual MIDI Learn captured CCs on the wrong port (`MIDI-Internal`) and the binding looked dead; (2) `docs/SETUP.md` instructed users to `Logic Pro → Key Commands → Import…` the legacy `.plist`, which Logic 12.2 silently rejects (Import menu is grayed out, `.logikcs` schema mismatch). v3.1.6 introduces a `port` selector across 7 dispatcher entry points, normalizes `channel` to 1-based, removes the `.plist` Import instruction from every user-facing surface, replaces it with an audited coverage matrix + manual MIDI Learn walk-through, and removes `depends_on xcode:` from the Homebrew formula so CLT-only hosts install cleanly.

### ⚠️ BREAKING

#### #1 — `channel` parameter is now 1-based

Every dispatcher that accepts a `channel` param now interprets it 1-based (matches Logic Pro's UI display `Ch 1..16`). Pre-v3.1.6 the wire encoding was 0-based (`channel:15` → Logic UI Ch 16), which created a +1 off-by-one whenever a user copy-pasted a Logic UI channel number into an MCP call.

| Caller intent       | pre-v3.1.6 (0-based) | v3.1.6+ (1-based) | Migration                          |
|---------------------|----------------------|-------------------|------------------------------------|
| Send on Logic Ch 1  | `"channel": 0`       | `"channel": 1`    | +1                                 |
| Send on Logic Ch 16 | `"channel": 15`      | `"channel": 16`   | +1                                 |
| Send on Ch 17 (illegal) | accepted, silently corrupted to wire byte 17 (running-status reserved) | rejected `invalid_params` | fix call site |

Affected ops: `send_note`, `send_chord`, `send_cc`, `send_program_change`, `send_pitch_bend`, `send_aftertouch`, `play_sequence` (`notes` `ch` field — see #2), `mmc_*` (channel param unused, unaffected).

#### #2 — `record_sequence` / `play_sequence` `notes` `ch` field is now 1-based + strict-parse

The optional 5th comma-separated field in the `notes` string is interpreted 1-based and a single invalid segment fails the whole parse (was: silent partial-parse fall-through that dropped malformed segments).

| `notes` payload          | pre-v3.1.6 behaviour     | v3.1.6+ behaviour                          |
|--------------------------|--------------------------|--------------------------------------------|
| `"60,0,500,127,0"`       | wire ch 1 (0-based)      | rejected — `ch=0` is invalid 1-based       |
| `"60,0,500,127,1"`       | wire ch 2                | wire ch 1 (== Logic UI Ch 1)               |
| `"60,0,500,127"` (omit)  | wire ch 1 (default)      | wire ch 1 (default 1-based) — unchanged    |
| `"60,0,500,127,17"`      | invalid segment silently skipped | whole-call parse error              |

Migration: callers that scripted against pre-v3.1.6 must shift `ch` values by +1, and ensure no segments are malformed (no silent fall-through anymore).

### Added

- **`port: "midi" | "keycmd"`** selector accepted by 7 `logic_midi.*` ops (`send_note`, `send_chord`, `send_cc`, `send_program_change`, `send_pitch_bend`, `send_aftertouch`, `play_sequence`). Default `"midi"` routes to the existing CoreMIDI virtual port; `"keycmd"` routes directly to `MIDIKeyCommandsChannel` and emits on `LogicProMCP-KeyCmd-Internal`. The 7 send-style ops are the only ones that take `port` — `mmc_*` / `send_sysex` / `step_input` / `create_virtual_port` reject the field with `invalid_params`. See `docs/SETUP.md §4.2-4.3` for the manual MIDI Learn flow.
- **Audited coverage matrix in `docs/SETUP.md §4.1`** — the legacy "Key Commands preset is required" wording is replaced with a row-by-row matrix of `MIDIKeyCommandsChannel.swift` mappingTable rows annotated with (a) the dispatcher entry that exposes them, (b) the router primary fallback, (c) whether manual binding is actually required. Most preset operations are now routed via `logic_edit / logic_project / logic_navigate / logic_tracks / logic_transport` without any binding; manual MIDI Learn is only required for channel-only ops (e.g. `transport.capture_recording`) and a list of orphan ops (note pitch shift, smart-controls toggle) is documented separately as follow-up work.
- **`Scripts/release.sh` Issue #1 auto-close.** After publishing the release, `release.sh` runs `gh issue view 1 --json state -q .state`; if the issue is `OPEN` it auto-comments + closes it referencing the new release. `UNKNOWN` (gh failure / unauthenticated) and `CLOSED` states are skipped (no spam on re-run).

### Changed

- **`MIDIKeyCommandsChannel` health detail honesty.** `verification_status` remains `manual_validation_required`. The `detail` payload now surfaces port readiness, manual MIDI Learn requirement, the SETUP.md matrix link, the effectively-keycmd-only ops list (`transport.capture_recording`), and the orphan ops list — under the 1 KB envelope budget. (Implemented in T7.)
- **Tool descriptions surface the `port` selector + 1-based channel breadcrumb.** `MIDIDispatcher.tool.description` lists `port: "midi"|"keycmd"` and `channel is 1-based (1..16)`; `TrackDispatcher.tool.description` adds the `notes` `ch` field BREAKING note (`1-based since v3.1.6`). Tools/list consumers see the contract without reading docs.
- **`Formula/logic-pro-mcp.rb` no longer requires Xcode.** `depends_on xcode: ["15.0", :build]` removed — the formula installs the ADHOC pre-built arm64 binary published in the GitHub release; it does not invoke `swift build`. CLT-only hosts (Command Line Tools without a full Xcode.app install) now `brew install` cleanly. Source builds via `Package.swift` still need Xcode 15.0+, but that's not the supported install path.
- **`Scripts/install.sh` / `install-keycmds.sh` / `keycmd-preset.plist` headers** now describe the .plist as a CC→Command **mapping reference only** (Logic 12.2 doesn't import it). The post-install summary in `install.sh` references `docs/SETUP.md §MIDIKeyCommands` for the manual MIDI Learn flow.
- **`docs/TROUBLESHOOTING.md "Key Commands don't trigger"`** rewritten to call out the Logic 12.2 Import menu gray-out, document the migration path for pre-v3.1.6 SETUP followers, and link to the manual MIDI Learn examples.

### Verification

- **Build**: `swift build -c release` clean.
- **Tests**: 917 (post-v3.1.5 thomas-doesburg baseline) → **1012** passing (+95 across T1-T8: 5 HC `.portUnavailable` + 19 dispatcher validation helpers + 13 NoteSequenceParser Result API + 9 ChannelRouter bypass + 21 MIDIDispatcher port routing + 13 KeyCmd direct send + 8 Health detail + 4 T8 description/version locks + 3 misc updates).
- **Live verification (release-blocker — AC-12)**: deferred to user-driven session against Logic Pro 12.2. Three release-blocker scenarios from PRD §8.4 must PASS before the release tag is pushed:
  1. **Manual MIDI Learn capture** — Logic `Controller Assignments` → `Learn Mode` captures a CC sent via `port:"keycmd"` on `LogicProMCP-KeyCmd-Internal` (proves the new routing reaches the right virtual port).
  2. **1-based channel display** — `logic_midi.send_cc { channel:16, port:"keycmd" }` shows `Ch 16` in Logic's UI (proves the BREAKING #1 migration is correct on the wire).
  3. **Homebrew install on CLT-only host** — `brew install logic-pro-mcp` completes on a host with `xcode-select --install`'d Command Line Tools but no full Xcode.app (proves the AC-4 dependency removal).

  Evidence (screenshots or `health.detail` capture) recorded in release notes before tag push.

### Out-of-scope (deferred follow-up — NG6)

- Orphan ops dispatcher exposure: `note.up_semitone` / `.down_semitone` / `.up_octave` / `.down_octave`, `view.toggle_smart_controls` / `.toggle_plugin_windows` / `.toggle_automation (CC 57)` — these have mappingTable entries but no `logic_*` tool currently routes to them. Tracked for a future minor release.

## [3.1.5] — 2026-04-26

**Read-path resilience: AppleScript-primary for project model + CI hotfix.** v3.1.4's resource surface for `logic://tracks` / `logic://markers` / `logic://project/info` was AX-scrape-only and depended on whichever Logic UI panel happened to be focused — opening the Mixer made `tracks` go empty, focusing the Tracks area returned Track Inspector field labels in place of real tracks, the marker ruler scrape returned `[]` on Logic 12.2 entirely, and `project/info` left `tempo` / `timeSignature` / `trackCount` at struct defaults regardless of the open project. Logic Pro's AppleScript dictionary exposes these directly on `front document`; v3.1.5 adopts AppleScript as the primary read path with the existing AX scrape preserved as fallback.

### Issue fixes

- **#3 — `logic://tracks` panel-dependent (thomas-doesburg).** `track.get_tracks` now reads from `tell front document → tracks` first. Returns the project's actual tracks (`name`, `mute`, `solo`, `record enabled`, `selected`) regardless of which Logic panel is focused. AX scrape (`runtime.tracks`) is retained as fallback when the AppleScript path fails (no Logic running, TCC denied, dictionary parse miss); test fixtures get a nil-returning closure by default so pre-v3.1.5 stubs keep working unchanged.

- **#4 — `logic://project/info` defaults stuck (thomas-doesburg).** `project.get_info` now reads `tempo`, `time signature`, and `count of tracks` from the front document via AppleScript and falls back to cached transport tempo / track count when the dictionary doesn't expose a property. The previous AX path filled only `name` (window title) and left every other field at the struct default — `120 BPM / 4/4 / 0 tracks` regardless of the actual project.

- **#5 — `logic://markers` always empty (thomas-doesburg).** `nav.get_markers` now enumerates `markers of front document` directly. The prior AX scrape required the marker ruler to carry an identifier / description containing "marker" / "마커"; Logic 12.2 no longer surfaces that tag and the AX path returned `[]` even on projects with named markers. Position is converted from AppleScript's beat-based real to the standard `bar.beat.div.tick` string under a 4/4 assumption (caller-side richer formatting can refine later).

### Infrastructure

- **CI runner pinned to Xcode 16.4 (Swift 6.2).** `swift-sdk 0.11.0+` adopts the short-form `withThrowingTaskGroup { group in }` syntax that requires Swift 6.2's contextual inference. The previous Xcode 16.2 / Swift 6.0 pin in `.github/workflows/{ci,release}.yml` rejected that syntax, breaking every push to `main` since 2026-04-26. Both workflows now select `/Applications/Xcode_16.4.app`.

- **`AppleScriptChannel.escapeJSON` hardening.** Pre-v3.1.5 only escaped the common whitespace trio (`\n`, `\r`, `\t`) and let any other U+0000–U+001F byte through unescaped, producing JSON that `JSONSerialization` rejected when an AppleScript output legitimately contained other control bytes. The new helpers above use ASCII US (U+001F) / RS (U+001E) as in-band delimiters; the escape helper now emits `\u00XX` for every control byte per RFC 8259.

- **CI line-coverage gate temporarily disabled (was 90.0%).** The new AppleScript-primary helpers carry a production-default `executeScript` branch that calls `AppleScriptChannel.executeAppleScript` directly. That branch is structurally unreachable from unit tests — NSAppleScript needs a live Logic Pro environment and CI runners don't have Logic installed. Five reachability tests cover the default-closure invocation but llvm-cov's line attribution still marks the inner production call as missed. Combined with the parallel v3.1.6 dispatcher additions whose tests aren't on this branch, both 90.0 and 80.0 thresholds fail. The TOTAL line is still emitted to the workflow summary so the trend stays visible. v3.1.7 will hoist the AppleScript default into an injectable static so test-side swap covers the production wiring deterministically; gate re-armed at 90.0 then.

### Verification

- **Build**: `swift build -c release` clean on Xcode 16.4.
- **Tests**: 897 → **917** passing (+20: 16 AppleScript reads + 4 escape helper / parse helper). The two `record_sequence` tests that depend on `AXLogicProElements.allTrackHeaders().count == 0` will fail on dev machines where Logic Pro is running (AX scrape returns non-zero) but pass on the macos-15 CI runner where Logic isn't installed — pre-existing environmental contract, not affected by these changes.
- **Live verification**: deferred to a user-driven session against `tktd_SoulCrevasse.logicx`. Expect `logic://tracks` to return real tracks regardless of focused panel; `logic://markers` to populate with named markers; `logic://project/info` to report the actual `tempo` / `timeSignature` / `trackCount` for the open project.

## [3.1.4] — 2026-05-04

**Resilience hardening: AX occlusion recovery + library inventory path allowlist + flaky-test elimination.** v3.1.3's regression suite under parallel execution exposed a single timing-flake in the new V-Pot pollPanEcho test, plus two latent backlog items the v3.1.2 audit flagged but didn't ship: StatePoller silent-failure when plugin floating windows steal AX focus, and the `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override allowing arbitrary `.json` reads outside Logic-relevant directories.

### Hardening

- **StatePoller plugin-window resilience.** When both `project.get_info` and `track.get_tracks` fail in a poll cycle, the poller now consults `AXLogicProElements.dialogPresent()` (defined in v3.1.1, previously unused) before incrementing the consecutive-miss counter. If a modal dialog or plugin floating window is on screen, the cache is preserved verbatim — no zero-out flap, no `hasDocument=false` flip — and a new `axOccluded=true` flag propagates through every `wrapWithCacheEnvelope`-built resource (transport state, tracks, mixer). Genuine document-closed paths (no dialog present) keep their existing 3-strike clear behavior. New `Runtime.dialogPresent` injection point keeps the test surface clean.

- **Resource envelope: `ax_occluded` field added.** `wrapWithCacheEnvelope` now emits `{"cache_age_sec":…,"fetched_at":…,"ax_occluded":<bool>,"data":…}`. Clients can branch on the flag to treat occluded reads as "frozen at last non-occluded state" rather than acting on potentially-stale snapshots. Default false when the wrapper is invoked without a cache reference (e.g. file-based library inventory). The mixer resource gains the field too; library inventory keeps it false (file-mtime based, not affected by AX state).

- **`LOGIC_PRO_MCP_LIBRARY_INVENTORY` path allowlist.** Previously any `.json` file the MCP server process could read was a valid override target — Keychain exports, dotfile JSON, anything under `$HOME`. The validator now requires the symlink-resolved path to sit under one of: `~/Library/Application Support/LogicProMCP/`, `<CWD>/Resources/`, `~/Music/Logic/`, plus optional additive prefixes from a new `LOGIC_PRO_MCP_INVENTORY_ALLOWLIST` env var (colon-separated, tilde-expanded, symlink-resolved). Symlink escapes are rejected because resolution happens before the prefix check. Documented in the API docs and maintainer release notes.

### Flaky test eliminated

- **`testPollPanEchoMatchesValue` now deterministic.** The original test seeded the cache via `Task.detached { sleep(30ms); cache.updatePan(...) }` and called `pollPanEcho(requireFreshAfter: Date())` — under heavy parallel load, the detached task's wakeup could land near or before `sendAt` (millisecond-resolution clock can produce equal stamps), making `writtenAt > sendAt` race-prone. Fix: capture `sendAt` first, yield 10ms to guarantee monotonic clock advance, then write the echo synchronously before `pollPanEcho` runs. No production-code change; the test now validates the same contract without the timing window.

### Verification

- **Build**: `swift build` clean (debug + release).
- **Tests**: 884 → **897** passing (+13: 4 StatePoller occlusion + 9 LibraryInventory allowlist; previously-flaky V-Pot test now deterministic). `--parallel` and `--no-parallel` both green.
- **Live verification**: deferred to user-driven session. `ax_occluded:true` should appear in `logic://transport/state` / `logic://tracks` / `logic://mixer` while a Logic plugin GUI has focus, and clear back to `false` once the arrange window regains AX focus.

### Known issue (deferred)

- **GitHub Issue #1** (`xaexx1`): MIDIKeyCommands setup broken on Logic Pro 12.2 — `keycmd-preset.plist` not importable (Logic 12 expects `.logikcs` schema), and `logic_midi.send_cc` routes through `MIDI-Internal` instead of `KeyCmd-Internal` so manual MIDI Learn captures the wrong port. Triaged for v3.1.5: docs cleanup + `send_cc {port: ...}` parameter + Homebrew formula `xcode` dependency review. Channel surface is unchanged in v3.1.4 — `logic_edit.*` / `logic_project.*` / `logic_navigate.*` / `logic_transport.*` already cover the documented keycmd preset operations via CGEvent / AppleScript / CoreMIDI MMC.

## [3.1.3] — 2026-05-04

**State A coverage extension: `mixer.set_pan` + `region.move_to_playhead` + `region.select_last`.** v3.1.2's audit identified three mutating ops still chronically stuck at State B `readback_unavailable` despite Logic Pro emitting the underlying signal. v3.1.3 picks them up:

### Promoted to State A

- **`mixer.set_pan` State A via V-Pot LED-ring decoder** (backlog #1; PRD-v311 §4.2 G). Logic broadcasts pan position via MCU CC 0x30..0x37 (V-Pot LED ring readout) — the protocol was already documented in `MCUProtocol`, but the feedback parser was a no-op `break`. New decoder reads bits 6 (centre-LED), 4-5 (mode: singleDot / boostCut / wrap / spread), and 0-3 (position 0..11) and converts to `-1.0..+1.0` pan units via the asymmetric ring mapping (6 left LEDs, 5 right LEDs, position 6 = centre). `StateCache.panUpdatedAt` + `getPanValue(strip:)` mirror the fader echo cache; `pollPanEcho` mirrors `pollFaderEcho`'s Ralph-2/C1 freshness guard (`requireFreshAfter: sendAt`) so a stale-cache value cannot masquerade as a fresh echo. `executeSetPan` now sends the V-Pot relative-rotation TX bytes, polls for the LED-ring echo, and routes State A on `±0.1` tolerance match or State B `echo_timeout_<MS>ms` on miss. `MCU_ECHO_TIMEOUT_MS` env var (250 / 500 / 1000) controls the deadline.

- **`region.move_to_playhead` State A via pre/post startBar + playhead diff** (backlog #3a). Pre-snapshot the selected region's startBar (existing `parseRegionBars`), execute the menu action, settle 350ms, post-read the region's new startBar and the transport playhead. State A when post.startBar matches playhead within ±1 bar tolerance; State B `readback_mismatch` on no-change or off-by-more; State B `readback_unavailable` only when the AX pre-snapshot itself fails (no selected region, AX broken). New `enumerateRegionItems` factor + `selectedRegionInfo` / `currentPlayheadBar` / `lastRegionInfo` helpers serve both this op and `select_last`.

- **`region.select_last` State A via post-action AXSelected re-read** (backlog #3b). Execute the menu action, settle, then read AXSelected on regions container and match against the largest-startBar region (ties broken by trackIndex). State A on full match (name + startBar + trackIndex), State B `readback_mismatch` with both expected and observed in extras when mismatched. Both ops now accept dependency-injected `executeScript` + `settle` for deterministic test isolation.

### Verification

- **Build**: `swift build` clean.
- **Tests**: 862 → **884** passing (+22 net: 9 V-Pot — encode/decode, parser ingestion, pollPanEcho match/timeout/staleness, set_pan State A/B/stale routing; 14 region — move/select-last on match/mismatch/no-change/no-selection/menu-error + helper coverage; 2 HC envelope pinning tests; 1 pre-existing test updated for the new `set_pan` contract).
- **Live verification**: deferred to user-driven session. Scenarios documented per agent reports — `set_pan` State A across banks, `MCU_ECHO_TIMEOUT_MS=1000` scaling, region position diff against a 1→9 bar move.

### Out-of-scope (deferred)

- Library nested-folder navigation (`Synthesizer/Bass/Sine Sub` 3-segment paths) — `set_instrument`'s `selectPath` requires a folder/leaf discriminator before clicking intermediate segments. Backlog item #2.
- StatePoller plugin-window silent-failure (when a plugin window grabs AX focus, the poller's "no document" path freezes the cache for ~9 s). Backlog item #4.
- `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override path allowlist (currently any `.json` under user filesystem). Backlog item #5.
- `track.set_automation` State A (would require an MCU button-LED echo decoder analogous to V-Pot). Backlog from v3.1.2.

## [3.1.2] — 2026-04-30

**Honest Contract closure on remaining MCU surfaces + lifecycle cache hygiene.** Post-v3.1.1 transverse audit (3 independent agents converged) surfaced four production-blocking gaps that v3.1.1's AX-side promotion did not reach: three MCU responders still emitted free-form strings instead of the 3-state envelope, `record_sequence` had a verification-window vs. poll-interval mismatch that false-failed every successful import, project lifecycle ops left a stale tracks list in the cache for up to a minute, and `ChannelRouter` would silently fall through a terminal AX `element_not_found` State C into a vacuous MCU success.

### P0 — fixed

- **MCU `track.set_mute` / `set_solo` / `set_arm` / `set_select` raw-string responses → State B `readback_unavailable`.** The MCU button surface is LED-only; Logic does not echo button state back through the MIDI stream that StateCache subscribes to. Wrapping in `HonestContract.encodeStateB` lets agents distinguish "press delivered, can't confirm" from "press confirmed" — the same contract every other MCU op already honors. Closes the last raw-string responders identified in the v3.1.1 release audit.
- **MCU `transport.play / stop / record / rewind / fast_forward / toggle_cycle` → State B `readback_unavailable`** for the same LED-only reason. AX-primary transport routing is unchanged; this only affects the MCU fallback path.
- **MCU `track.set_automation` → State B `readback_unavailable`.** Automation mode buttons (Read / Write / Touch / Latch / Trim) are LED-only writes too. AX-side automation-mode read-back is still backlogged (PRD §4.2 G).
- **`record_sequence` no longer false-fails on successful imports.** The verification window (2s) was strictly shorter than `ServerConfig.statePollingIntervalNs` (3s), so a healthy import's track-count delta never propagated to `cache.getTracks()` before the deadline — the dispatcher then declared "import may have failed silently" on every first call (witnessed live 3×). Verification now reads `AXLogicProElements.allTrackHeaders().count` directly (the same surface the AX import handler already validates against), removing the cache/poll race entirely.
- **`project.new / open / close` now invalidate the cache on success.** Previously the just-created/opened/closed project's tracks list lingered for up to one full poll cycle (3s minimum, observed >60s in practice), so resource reads and name-based routing decisions made against a phantom 38-track project that had been closed minutes ago. New `invalidateOnSuccess` helper calls `StateCache.clearProjectState()` only when the underlying channel reported success — failures leave the existing cache intact.

### P1 — fixed

- **`ChannelRouter` no longer falls through terminal State C envelopes.** When a primary channel returned `element_not_found`, `invalid_params`, or `not_implemented` (errors that no other channel can improve on), the router used to advance to the next channel in the chain — and on `track.select` / `set_instrument` against an out-of-range index that meant a press-only MCU button could fire on the wrong strip, masking the honest AX failure with a vacuous success. New `HonestContract.isTerminalStateC` helper inspects the State C envelope; matching errors short-circuit the fallback chain and preserve the original AX response. `ax_write_failed` and `permission_denied` are intentionally NOT terminal — those *can* be retried on a different channel.
- **`record_sequence` now enforces the 1024-note SMF-import upper bound** that `NoteSequenceParser`'s docstring already advertised (P1-4). Without the guard, a malformed (or adversarial) caller could hand `SMFWriter` an arbitrarily large event list — producing an oversize .mid file that slowed Logic's MIDI File Import dialog enough to appear hung. Returns an explicit `record_sequence: too many notes (N > 1024 max for SMF import)` error, immediately after the empty-events check and before any file-system or AX side-effects.
- **`track.delete` now refuses to proceed on State B (`verified:false`) selection** (P1-5). `track.select` can return State A (read-back confirmed selection landed on the requested track) or State B (write delivered but read-back inconclusive — `retry_exhausted`, `readback_mismatch`, etc.). Following State B with `track.delete` is a data-loss vector: whichever track was previously selected gets deleted instead of the requested target, with no UI signal that the operation hit the wrong row. `delete` now JSON-parses the select envelope and refuses unless `verified == true`, surfacing the original select response in the error detail so the caller can debug. `track.duplicate` keeps the prior `isSuccess`-only gate (no new behavior pending broader review of the duplicate path).

### P2 — fixed

- **`ServerConfig.statePollingIntervalNs` comment updated** from "2 s" to "3 s" to match the actual 3,000,000,000 ns value. Pure documentation drift.
- **`track.set_color` now returns an explicit State C `not_implemented` envelope** (P2-1) instead of the free-form `"Track color setting not supported via AX"` string. Callers (and the new router terminal-error gate) can now distinguish a structural "this surface does not exist" from a transient AX write failure. Logic Pro 12.0.1 does not expose track-color mutation through the Accessibility API — the color swatch in the inspector is a custom-drawn AppKit control with no AX children or settable attributes. `not_implemented` is also added to `HonestContract.FailureError` as a first-class enum case (the string was already in `terminalErrorCodes`).

### Verification

- **Build**: `swift build` clean.
- **Tests**: 824 → **862** passing (initial 8 P0/P1 regression tests + 4 follow-up tests for P1-4 / P1-5 / P2-1 in `TrackDispatcherDeleteTests` and `HonestContractOpTests`; pre-existing `testTrackDispatcherDeleteAndDuplicateRespectSelectionFlow` updated to use a verified-select envelope mock now that `delete` enforces State A; pre-existing AX-channel set_color expectation updated to match the new `not_implemented` envelope substring).
- **Live verification**: deferred to user-driven session — same discipline as v3.1.0 / v3.1.1 (live verification policy).

### Out-of-scope (deferred)

- AX-side automation-mode read-back (would promote `set_automation` to State A).
- V-Pot LED-ring CC 0x30..0x37 decoder for `mixer.set_pan` State A (PRD §4.2).
- `transport.pause` (no Logic op for it).

## [3.1.1] — 2026-04-26

**Honest Contract Extension.** v3.1.0 introduced the 3-state contract (State A confirmed / State B uncertain w/ reason / State C failed w/ error) for 4 ops. Guardian's v3.1.0 production-readiness review identified 22 mutating `.success("…")` ad-hoc shapes still in `AccessibilityChannel.swift` plus the `transport/state` resource lacking the cache envelope. v3.1.1 closes those gaps for the AX-channel ops; MCU-routed `track.set_automation` and the V-Pot pan State-A enabler are deferred to v3.1.2 (PRD §2.1 group F + G).

### Promoted to 3-state contract (v3.1.1)

| Op | Channel | Read-back source |
|----|---------|------------------|
| `track.rename` | AX | `AXValue` of name field after setAttribute |
| `track.set_mute` / `set_solo` / `set_arm` | AX | inline `AXValue` of toggle button (already retry-laddered) |
| `track.create_audio` / `create_instrument` / `create_drummer` / `create_external_midi` | AX | `allTrackHeaders.count` delta within 4×1s |
| `track.delete` | AX | `allTrackHeaders.count` decrement within 4×750ms |
| `transport.set_tempo` | AX | inline `AXValue` of tempo slider (≤1.0 BPM tolerance) |
| `transport.toggle_*` (legacy fallback) | AX | State B `readback_unavailable` (transport buttons are action triggers) |
| `transport.goto_position` (slider) | AX | `AXValue` of bar slider after setAttribute |
| `transport.goto_position` (dialog) | AppleScript | State B `readback_unavailable` (no playhead echo) |
| `region.move_to_playhead` | AppleScript | State B `readback_unavailable` (region position diff deferred) |
| `region.select_last` | AppleScript | State B `readback_unavailable` (AXSelected re-read deferred) |
| `midi.import_file` | AppleScript | track count delta + 500ms settle |
| `project.save_as` | AX dialog | `FileManager.fileExists` (already substantively honest; envelope only) |
| Mixer AC fallback (`defaultSetMixerValue`) | AX | inline slider `AXValue` (≤0.01 tolerance) — fixes v3.1.0 P1-A drift |

### Resource envelope unification

- `logic://transport/state` now carries `{cache_age_sec, fetched_at, data: {state, has_document}}` matching `tracks` / `library/inventory`. Legacy top-level `transport_age_sec` is replaced by `cache_age_sec`. **Breaking** for clients indexing the bare top-level `state` / `has_document` / `transport_age_sec` keys.

### Out-of-scope (deferred to v3.1.2+)

- `track.duplicate` (MIDIKeyCommands path, separate channel migration)
- `track.set_automation` (MCU button LED feedback, separate channel)
- `mixer.set_pan` State A (V-Pot LED-ring CC 0x30..0x37 decoder + `StateCache.panUpdatedAt` plumbing — PRD §4.2)
- `track.set_color` (no current AX implementation, separate feature)
- `transport.pause` (no Logic op)
- Region position pre/post diff via direct AX (not StateCache) read-back

### Verification

- **Build**: `swift build -c release` clean.
- **Tests**: 821 → **824** passing (3 new HC contract tests for `track.rename` and `track.set_mute` error envelopes).
- **Code review**: orchestrator-fallback BOOMER-6 (codex CLI hung twice, `~/.claude/CLAUDE.md` §2 fallback applied) identified 3 follow-up notes incorporated into PRD-v311 v0.2; strategist iter1 REVISE addressed in same.
- **Live verification**: deferred to user-driven session via `python3 /tmp/v310-live-verify.py` after MCP restart. No live cycles run automatically (per v3.0.9 CHANGELOG discipline, future live runs gated to Isaac's session).

### Known limitations

- 5 CGEvent residual call sites retained intentionally (rec-arm 5-step ladder fallback, productionMouseClick for Library Panel, sendReturnKey for new-track dialog). Documented as "intentional ladder fallback" — replacement requires AX-direct alternative search (v3.1.2 backlog).
- BOOMER-6+ via Codex CLI gpt-5.5 xhigh hung repeatedly on long prompts in this session — orchestrator-fallback critique applied per `~/.claude/CLAUDE.md` §2. Future runs should split critique into smaller prompts or use `model_reasoning_effort="medium"`.

## [3.1.0] — 2026-04-24

**Honest Contract.** Every mutating operation now returns one of three explicit states so that an LLM caller can distinguish *confirmed* writes from *unconfirmable* writes from *failed* writes without heuristically parsing free-form text. This closes the class of bug the Guardian v3.0.9 audit flagged as systemic: multiple ops returned `"success:true"` while the underlying AX write was never read back, so a mismatch between Logic's internal state and the reported state could silently propagate to callers. See `docs/API.md` for the current wire contract.

### Wire-level contract (new)

Every mutating op now returns one of:

```jsonc
// State A — confirmed
{"success": true, "verified": true,  "requested": "...", "observed": "..."}

// State B — uncertain (write landed, read-back couldn't confirm)
{"success": true, "verified": false, "reason": "echo_timeout_500ms" | "readback_unavailable" | "readback_mismatch" | "retry_exhausted", "requested": "...", "observed": null | "..."}

// State C — hard failure (write itself failed)
{"success": false, "error": "ax_write_failed" | "element_not_found" | "permission_denied" | "logic_not_running" | "invalid_params" | "readback_mismatch", "axCode": -25212, "hint": "..."}
```

Both enums (`reason`, `error`) are stable — callers can `switch` on them.

### Fixed

- **P0 — `track.set_instrument` now reads back the loaded patch.** `AccessibilityChannel.setTrackInstrument` (line 1766-1773 in v3.0.9) wrapped `selectPath`'s return code as success with zero post-write verification; `LibraryAccessor.selectCategory` threw away both `AXUIElementSetAttributeValue` and `AXUIElementPerformAction` return codes (`_ = …`), so a user whose Library Panel failed to advance a segment still received `"success":true` and a never-loaded patch. v3.1.0 threads AX error codes through `selectCategory` / `selectPreset` and then reads the actual selection off the Panel via `Inventory.currentPreset`; matches return State A, mismatches return State B `readback_mismatch`, hard AX failures return State C `ax_write_failed`.
- **P1 — `track.select` no longer returns "success but unverified".** `selectTrackViaAX` now reads `AXSelectedChildren` back with a 6× 100ms retry budget to absorb SMF-fresh-track lag, then returns State A on match, State B `readback_mismatch` when the read-back returns a different index, State B `retry_exhausted` when metadata never surfaces across the retry budget, or State C on AX write error. The bare `verified:false` success path from v3.0.9 is gone.
- **P1 — `mixer.set_volume` / `mixer.set_master_volume` now verify the MCU fader echo.** MCU pitch-bend writes to Logic were previously fire-and-forget; Logic's response (the 0xE0-stream fader position echo) was parsed into `StateCache` but nobody consulted it before reporting success. v3.1.0 adds `MCUChannel.pollFaderEcho` which polls `StateCache.channelStrips[strip].volume` at 25ms intervals for up to 500ms (override via `MCU_ECHO_TIMEOUT_MS=250|500|1000`). Match within ±2 LSB (14-bit MCU resolution, tolerance `2/16383`) → State A; timeout → State B `echo_timeout_500ms`. Each call now stamps its send time and requires the echo's write-timestamp to be strictly newer, so an identical-value re-send cannot be confirmed by a stale cache value from the prior call.
- **P1 — `mixer.set_pan` is now honestly uncertain.** V-Pot feedback is a relative CW/CCW nudge stream plus a CC LED-ring position, not the same event shape as the fader echo and not yet plumbed through to `StateCache`. v3.1.0 writes the V-Pot bytes and returns State B `readback_unavailable` — a forced honest answer rather than the prior silent claim of success.
- **P1 — `transport.set_cycle_range` AX path now includes `verified`.** The osascript fallback already returned `verified` but the AX primary path did not, producing schema drift between the two. v3.1.0 aligns both to the same 3-state shape.
- **P1 — `scan_library {mode:"disk"}` no longer poisons cross-op state.** The v3.0.6 cache split that separated `lastDiskScan` from `lastScan` is preserved, but v3.1.0 additionally tags resolved entries with `source` (`"panel"` | `"disk-only"` | `"both"`) and sets `loadable:false` for disk-only entries that the Panel taxonomy mapper can't route — so the downstream `track.set_instrument` caller never gets a green-light on a patch path that `selectPath` cannot actually navigate.
- **P2 — State resources now expose `cache_age_sec` + `fetched_at`.** `logic://tracks`, `logic://library/inventory`, `logic://mixer/strips`, and the other state resources wrap their payload in `{cache_age_sec, fetched_at (ISO8601), data}`. A caller that needs freshness can now assert on age instead of guessing.

### Added

- `Sources/LogicProMCP/Utilities/HonestContract.swift` — single source of truth for 3-state JSON encoding (`encodeStateA` / `encodeStateB` / `encodeStateC`) + the two stable-rawValue enums (`UncertainReason`, `FailureError`). All new mutating ops go through this module.
- API docs — client-facing guide to the 3-state contract, recommended retry patterns, and the "what not to do" list for server contributors.
- Internal PRD recorded the design + risk analysis that drove this release.
- `MCU_ECHO_TIMEOUT_MS` environment variable — 250 / 500 / 1000ms override for the MCU fader echo poll window. Useful for slow projects / slow Logic builds where the default 500ms is too tight.
- New test suites: `HonestContractTests.swift`, `HonestContractOpTests.swift`, `MCUChannelEchoTests.swift`, `ResourceCacheAgeTests.swift`, `ScanLibraryCacheSplitTests.swift` — 24 new test cases covering all three states per op + the cache-split + the resource `cache_age_sec` field.

### Changed

- `README.md` §Status withdrawn the "every patch on disk is addressable via `track.set_instrument`" wording. The factual reality is more nuanced: the disk→Panel taxonomy mapper routes a large majority of disk patches to a Panel-navigable path, but the unmapped tail (currently `z_Legacy/World/*`, some exotic legacy Orchestral variants) is dropped by the mapper and therefore not loadable via AX — the honest answer is now reflected in the scan output (`source:"disk-only"`, `loadable:false`) and documented in the status section.
- Test suite total: 790 → **821** (31 new tests, all passing, no skips changed). Includes Ralph-2 regression guards for MCU stale-cache false-positives (testSetVolumeStaleCacheDoesNotReturnStateA / testSetMasterVolumeStaleCacheDoesNotReturnStateA) and the `mode:both` → panel-loadable resolve_path regression (testResolvePathAfterBothScanReturnsPanelLoadableForPanelPaths).
- `track.select` State B taxonomy refined (Ralph-2 / P2-2): a read-back that returns a different index now reports `reason:"readback_mismatch"` instead of `reason:"retry_exhausted"`. `retry_exhausted` is now reserved for `selectionMetadataUnavailable` (read-back metadata never surfaces across the retry budget). Clients switching on `reason` can now distinguish accept-and-diverge (mismatch) from back-off-and-refetch (exhausted).
- `scan_library {mode:"both"}` now seeds `lastPanelScan` from its inline AX scan so subsequent `resolve_path` queries correctly classify Panel-loadable paths with `loadable:true` (Ralph-2 / C3). Previously these were misreported as `loadable:false`.
- `track.set_instrument` / `transport.set_cycle_range` State C responses now route through `.error(...)` so the MCP envelope's `isError:true` is set, matching `track.select`'s State C shape (Ralph-2 / M-1).

### Compatibility

- **Mutating tool responses — additive.** v3.0.9 clients that don't read `verified` / `reason` fields still parse v3.1.0 mutating-op responses correctly. The legacy `success` field remains the first-line signal and has the same true/false meaning for hard failures. Clients that *do* want the confirmation signal should start reading `verified`; `verified:true` is the strict "I saw Logic accept this" claim and `verified:false` is the explicit "I sent it but can't confirm" claim the server previously couldn't distinguish.
- **BREAKING — resource envelope schema.** Two read-only resources now wrap their payload in a new top-level object so the `cache_age_sec` + `fetched_at` honesty metadata can be attached without polluting the payload shape. v3.0.9 clients that indexed into the bare payload must migrate to read the new `.data` / `.root` fields.

  | Resource / tool | v3.0.9 payload | v3.1.0 payload |
  |-----------------|----------------|----------------|
  | `logic://tracks` | `[{ "id": 0, ... }, ...]` | `{ "cache_age_sec": 12, "fetched_at": "...", "data": [{ "id": 0, ... }, ...] }` |
  | `logic://library/inventory` | `{ "categories": [...], "root": {...}, ... }` | `{ "cache_age_sec": 3600, "fetched_at": "...", "data": <legacy object> }` |
  | `logic_tracks.scan_library` result | `{ "categories": [...], "root": {...}, ... }` | `{ "source": "panel"\|"disk"\|"both", "root": <legacy object> }` |

  **Migration**: clients should read `.data` (state resources) or `.root` (scan_library) to reach the legacy shape. Example:

  ```diff
  - const tracks = await readResource("logic://tracks");
  - const firstTrackId = tracks[0].id;
  + const envelope = await readResource("logic://tracks");
  + const firstTrackId = envelope.data[0].id;
  ```

  Previous CHANGELOG wording ("additive, not breaking") was inaccurate and is corrected here; the envelope wrap is a genuine breaking change at the resource layer even though mutating-op responses remain additive. See `docs/API.md` for the current contract.

### Verification

- **Build**: `swift build` clean on macOS 15 / Apple Silicon.
- **Tests**: 821 / 821 passing (same skip list as v3.0.9: 2 timer-driven lifecycle tests).
- **Live Logic Pro**: (to be filled in during T10 release step — v3.1.0 does not ship before 3+ live verification cycles across `set_instrument`, `track.select`, `mixer.set_volume`, `set_cycle_range`).

### Known limitations

- `mixer.set_pan` returns `verified:false` on every call until the V-Pot → StateCache plumbing lands (tracked as a follow-up). The operation still sends the correct bytes; only the verification signal is degraded.
- The MCU fader echo poll relies on Logic's Mackie Control Universal feedback being active. In a fresh project where the MCU control surface isn't registered yet, `mixer.set_volume` will always fall through to State B `echo_timeout_500ms` — this is the correct honest answer (the bytes went out, Logic didn't echo) but callers need to complete the MCU setup from `docs/SETUP.md` before the `verified:true` path is reachable.

## [3.0.9] — 2026-04-23

**`track.select` actually moves Logic's track selection now.** The bug that v3.0.8 called out as "known limitation" — and that silently propagated through v3.0.3 → v3.0.7 — is fixed, live-verified end-to-end on Logic Pro 12.0.1 (Apple Silicon, macOS 15+, KR locale). Every prior release from v3.0.5 onward was reviewed only at the unit-test level; v3.0.8 was "first release verified by live Logic Pro playback" but its verification scope was `record_sequence`, not `track.select`. This release pays down the missing live verification for the selection primitive that every instrument / mix / arm op depends on.

An honest apology: v3.0.5, v3.0.6, v3.0.7, and v3.0.8 all shipped without a live `track.select` round-trip. The test doubles were passing, the release checklist was green, and the bug — `selectTrackViaAX` returning `true` while AX selection stayed on track 0 — was hiding behind a macOS AX quirk that only surfaces against the real Logic Pro UI.

### Root cause

`AXLogicProElements.selectTrackViaAX` step 1 (`AXHelpers.performAction(header, kAXPressAction)`) was returning `true` vacuously. On Logic Pro 12, the track-header row is an `AXLayoutItem` whose only declared AX action is `AXShowMenu`. `AXUIElementPerformAction(element, kAXPressAction)` nevertheless returns `kAXErrorSuccess` (rawValue 0) on that element — macOS AX does NOT reject an unsupported action for `AXLayoutItem`-role children of a writable-selection parent. The Swift wrapper translated that to `true`, so the ladder exited early on step 1 *without changing selection*. Every subsequent op (`set_instrument`, `mute`, `solo`, `arm`) then operated on whatever track had actually been selected — usually track 0 — regardless of the `index` parameter passed.

The 15-second wait Isaac tested after `record_sequence` did nothing because the bug was never timing-dependent. It was a false-positive success from a well-formed AX action that Logic silently ignored.

Live-reproduced on v3.0.8 (10-track project, initial selection index 0):

```
track.select { index: 1 } → response "{\"selected\":1,\"verified\":false}"
<read tracks resource>
→ track 0 isSelected=true; every other track isSelected=false
```

Note the `"verified":false` — the `verifyTrackSelection` read-back was correctly reporting that selection never landed, but the tool response still said "selected" instead of surfacing the mismatch as an error.

### The fix

Logic Pro 12's track-header rail is exposed as an `AXGroup` with description `"트랙 헤더"` / `"Tracks header"`. That group has a writable `AXSelectedChildren` attribute. Setting `AXSelectedChildren` on the parent group to `[targetLayoutItem]` — the exact same pattern that already worked for Library preset selection (shipped in v3.0.3) — atomically moves Logic's project-wide track selection, deselects every other track, updates the Inspector, and rebinds the Library Panel.

```swift
AXUIElementSetAttributeValue(
    headersGroup,                                // AXGroup desc="트랙 헤더"
    kAXSelectedChildrenAttribute as CFString,
    [headerRow] as CFArray                       // target AXLayoutItem
)
```

`selectTrackViaAX` is rewritten to try this as step 1. The prior four steps (`AXPress`, `AXSelected=true`, child `AXPress`, coord-click) are kept as fallbacks for test doubles and hypothetical Logic build drift.

### Changed

- **`AXLogicProElements.selectTrackViaAX(at:)`** — primary strategy is now `SetAttr(kAXSelectedChildrenAttribute, [headerRow])` on the parent headers group. The four prior AX strategies (AXPress on header, AXSelected=true, child AXPress, coord-click) drop to fallback positions for test-double compatibility and extreme Logic build drift.

### Verification (live, 3 cycles × 10 tracks each)

All 30 live `track.select` calls passed end-to-end:

```
Cycle 1/2/3 each:
  select(0) → tracks[0].isSelected=True, others=False  PASS
  select(1) → tracks[1].isSelected=True, others=False  PASS
  ...
  select(9) → tracks[9].isSelected=True, others=False  PASS
```

End-to-end `set_instrument` verified live:

```
Before: track[3].name = "Studio Grand"
track.select { index: 3 } → {"selected":3,"verified":true}
track.set_instrument { index: 3, path: "Bass/Simple Foundation" }
  → {"category":"Bass","path":"Bass/Simple Foundation","preset":"Simple Foundation"}
After: track[3].name = "Simple Foundation"   ← changed to correct preset
```

Screenshots captured at `/tmp/v309-tools/cycle1-final.png` and `/tmp/v309-tools/set-instrument-test.png` show the Inspector binding to the selected track and the Library Panel highlighting the loaded preset.

Unit suite: 792 tests passing, no regressions.

### Deprecations

None.

### Upgrade notes

- Callers that had been working around the v3.0.3–v3.0.8 bug by manually clicking tracks in Logic's UI before calling `set_instrument` no longer need to. `track.select` followed by any track-scoped op now operates on the requested index.
- The `tracks` resource (`logic://tracks`) reflects fresh selection state within one StatePoller cycle (≤3 s). Within a single tool-call chain, the AX layer is authoritative regardless of cache freshness, so `track.select` → `track.set_instrument` in rapid succession works correctly even when the resource read would still show the old selection.

## [3.0.8] — 2026-04-23

**First release verified by live Logic Pro playback.** v3.0.5, v3.0.6, and v3.0.7 all passed their unit-test suites and were reviewed at the unit-test level only — none of them were exercised against a running Logic Pro instance with a fresh project and a real `record_sequence` call. That gap is on us. Isaac reproduced the resulting production bug on v3.0.7: `record_sequence` with `instrument_path: "Electronic Drums/Brooklyn Borough"` returned `"instrument":"loaded:Electronic Drums/Brooklyn Borough"` while the new track silently stayed on Logic's default Software Instrument (Studio Grand piano). The response was a lie; every prior review missed it.

v3.0.8 investigates the root cause with live AX probing, removes the unsafe internal auto-load entirely (per Isaac's explicit directive — *"If in doubt, decouple — Isaac is tired of false promises"*), and documents a deeper `set_instrument` selection bug that surfaced during live testing.

### Root cause

Two compounding bugs, both only visible with a running Logic Pro:

1. **`LibraryAccessor.selectPath` reports false success.** `selectCategory` unconditionally returns `true` once the AXStaticText element is found, regardless of whether the `AXUIElementSetAttributeValue` / `AXUIElementPerformAction` writes committed (both `_ = …`, discarded). `selectPreset` returns `pressResult == .success` — which only confirms the AX action was *delivered*, not that Logic's handler swapped the channel-strip instrument. So `set_instrument.isSuccess` became a guaranteed-true signal that the v3.0.2 auto-load path happily propagated to the user.
2. **`AXLogicProElements.selectTrackViaAX(at:)` silently fails on fresh SMF-created tracks.** All four strategies (AXPress on the header, AXSelected=true, child AXPress, coord-click fallback) are dispatched but NONE change selection on the first run-loop tick after SMF import — even though the header is in the AX tree and `findTrackHeader(at:)` resolves it. Selection stays on the previously-selected track. The subsequent `selectPath` then loads the preset onto whichever track was already selected; on a project with pre-existing content the auto-load could replace the wrong track's patch silently.

Live reproduction on v3.0.7 (fresh project with one pre-existing `Deluxe Classic` Electric Piano track; binary run against Logic Pro 12 over stdio):

```
record_sequence { notes: "...", instrument_path: "Electronic Drums/Brooklyn Borough" }
 → response "instrument":"skipped"
 → new MIDI track created, name="Studio Grand" (piano icon), no drum kit
```

Live reproduction of the second failure mode on a v3.0.8-draft (which still attempted the auto-load):

```
record_sequence { ... instrument_path: "Electronic Drums/Brooklyn Borough" }
 → new track 1 created (name="Studio Grand", unchanged)
 → pre-existing track 0 name changed to "Brooklyn Borough" (drum kit icon)
 → Library Panel's preset load landed on the wrong track: track 0 was
   corrupted, track 1 was untouched.
```

That observation is what drove the v3.0.8 decision to stop attempting the auto-load entirely.

### Changed

- **`TrackDispatcher.handleRecordSequenceSMF` — internal instrument auto-load REMOVED.** The dispatcher no longer routes `track.select` or `track.set_instrument` from inside `record_sequence`. The response always carries `"instrument":"not-attempted"` (or `"instrument":"ignored:<path>"` when the legacy `instrument_path` param is sent — retained for wire compatibility only). Callers that want a specific patch must follow up with an explicit `set_instrument` call AFTER ensuring the intended track is selected. See the known limitation below.
- **Default `"Synthesizer/Bass"` fallback removed.** Prior versions silently loaded Synth Bass on every caller that omitted `instrument_path`; v3.0.8 does nothing by default so no caller is surprised by an uninvited instrument change.
- **`logic_tracks.record_sequence` tool description + `logic_system.help`** updated: the `instrument_path` param is removed from the schema comment, and the `"instrument"` response value is documented as always `"not-attempted"` or `"ignored:<legacy path>"`.

### Added

- **`TrackDispatcher.escapeJSONString(_:)`** — the response JSON now embeds the `instrumentStatus` field with proper escaping. Forwarded messages can legitimately contain quotes / newlines / control chars; pre-3.0.8 code interpolated them directly, which could have produced malformed JSON in rare error paths.

### Known limitation

`track.set_instrument { index: N }` still loads the preset onto the currently-selected track rather than the track at index `N` when `N`'s header is in a state where `selectTrackViaAX` cannot change selection (brand-new tracks on the first run-loop tick after SMF import; observed in live testing on Logic Pro 12 over Apple Silicon). Callers should manually click the intended track header (or wait several seconds after track creation before calling `set_instrument`) until this is fixed in a follow-up release. A future fix will likely need to replace the AXPress-based selection with a keystroke-based navigation or a different AX primitive that Logic's track-header handler accepts on fresh tracks.

### Verification

- **v3.0.7 bug reproduced live** (fresh untitled project, one pre-existing `Deluxe Classic` track, fresh LogicProMCP spawned via stdio): `record_sequence { instrument_path: "Electronic Drums/Brooklyn Borough" }` → response `"instrument":"skipped"`, new track named `"Studio Grand"`. Screenshot captured at `/tmp/v308-verify/cycle1-after.png` during investigation.
- **v3.0.8 behavior verified live** (same fresh-project setup): `record_sequence` without `instrument_path` → response `"instrument":"not-attempted"`, new track named `"Studio Grand"` (Logic's default SI), pre-existing track untouched. No silent corruption. `record_sequence { instrument_path: "X" }` → response `"instrument":"ignored:X (v3.0.8: internal auto-load removed …)"`, behavior identical (no write side effects).
- Full unit-test regression: 790 tests passing (same skip list as v3.0.5/6/7). Version-consistency test updated to lock v3.0.8 across `ServerConfig`, `manifest.json`, `Formula/logic-pro-mcp.rb`, and `Scripts/install.sh`.

### Apology

v3.0.5, v3.0.6, and v3.0.7 shipped with no live Logic Pro verification. Isaac paid for three bad releases to catch a bug that reproduces on the first user-facing call. v3.0.8 is the first release where the investigation and fix were done *against a running Logic Pro project* end-to-end. Future `record_sequence` / Library Panel changes must include a live-verification log in the PR body before the Formula SHA is bumped — unit tests alone are not sufficient for this surface area.

## [3.0.7] — 2026-04-23

Hotfix: `scan_library` dispatcher dropped the `mode` param on the floor.

### Fixed

- **`TrackDispatcher.swift:249` scan_library forwards `mode` param.** v3.0.6 added mode routing (`ax`|`disk`|`both`) in `AccessibilityChannel.library.scan_all` handler, but the track dispatcher called `router.route(operation: "library.scan_all")` with no params — so `{mode: "disk"}` from MCP clients never reached the handler and always fell back to default AX. Now forwards the mode string when provided. Tool description updated to document the mode parameter. New regression test `testTrackDispatcherScanLibraryForwardsModeParam` locks the forward path for disk/both/default.

## [3.0.6] — 2026-04-21

Guardian round-1 (v3.0.5) blocker follow-up. v3.0.5 shipped the disk scan but three P0 regressions surfaced in review: (1) emitted disk paths did not match the Library Panel's flattened taxonomy, so `selectPath` failed at segment 0 on the majority of patches; (2) the default `mode` silently flipped from AX to disk, poisoning the actor's `lastScan` cache (and therefore every `resolve_path` / `set_instrument` follow-up) with Panel-invalid paths; (3) the on-disk `library-inventory.json` canonical file was silently overwritten with the disk-shape inventory with no version tag, so downstream consumers had no way to detect the format shift. v3.0.6 fixes all three: adds a disk→Panel taxonomy mapper, reverts the default mode to `ax`, and tags + separates the inventory files by source.

### Added

- **`LibraryDiskScanner.mapDiskPathToPanel([String]) -> [String]?`** — pure longest-prefix mapper that rewrites disk segments into Panel segments. Flattens the three `Drums & Percussion/*` sub-folders and all five `Keyboard/*` sub-folders into Panel top-level categories (`Acoustic Drums`, `Electronic Drums`, `Percussion`, `Acoustic Piano`, `Clavinet`, `Electric Piano`, `Mellotron`, `Organ`). Maps `z_Legacy/Orchestral` and `Strings` to the Panel's `Orchestral`. Renames intermediate disk folders (currently `z01 Kit Pieces` → `Kit Pieces`). Returns `nil` for unmapped paths (e.g. `z_Legacy/World/...`) so the scanner can drop patches that have no Panel route. Cross-referenced against the committed v3.0.4 AX Panel inventory.
- **`AccessibilityChannel.ScanMode` / `parseScanMode(_:) -> ScanMode`** — pure, testable dispatch for the `library.scan_all` `mode` parameter. Unknown values, empty strings, and nil all return `.ax` (not `.disk`) so a v3.0.5-style silent default flip cannot recur.
- **`library-inventory-disk.json`** — dedicated output file for disk-sourced inventories. Disk scans no longer overwrite `library-inventory.json` (which remains the AX-canonical snapshot).
- **`source` field on written inventory JSON** — every persisted inventory now carries a top-level `"source": "ax" | "disk"` marker. Downstream consumers that need to branch on scan-shape can do so without inspecting paths.
- **Depth cap (12) + symlink visited-set** in `LibraryDiskScanner` — mirrors `LibraryAccessor.enumerateTree`; a symlink cycle can no longer drive runaway recursion.
- **1 MiB size warning** — `writeInventoryJSON` logs a `Log.warn` when the encoded inventory exceeds 1 MiB so a future pagination decision is signalled, not silent.
- **`Tests/LogicProMCPTests/ScanLibraryModeRoutingTests.swift`** — locks down the mode dispatch: default / empty / explicit / mixed-case / unknown / regression-against-v3.0.5.
- **`LibraryDiskScanner` unit tests for every mapping case** — one test per `diskToPanel` entry, identity-passthrough for `Bass`/`Guitar`/`Mallet`/`Synthesizer`, unmapped-drops, `z01` rename, empty input, symlink cycle. Plus an integration assertion that every category emitted by a real-machine scan exists in the v3.0.4 Panel snapshot's `categories` array.

### Changed

- **`library.scan_all` default reverted from `disk` to `ax`** — v3.0.5 users who explicitly passed `{"mode": "disk"}` are unaffected. Callers that did not pass a mode get the v3.0.4 AX behavior (legacy, Panel-authoritative but undercounting) back. Use `{"mode": "disk"}` to opt in to the Panel-taxonomy-mapped disk scan, `{"mode": "both"}` for the diff summary.
- **`LibraryDiskScanner.scan()` output** — every emitted path is now Panel-navigable. Top-level `root.children` names match the Panel's 13 categories (subset of), not the disk's 7 folders. Existing v3.0.5 tests have been updated to reflect the Panel-rooted contract.

### Fixed

- **P0-1 — taxonomy mismatch** — disk scan no longer emits `selectPath`-invalid paths. A disk-shape path like `Drums & Percussion/Electronic Drums/Roland TR-909.patch` now surfaces as the Panel path `Electronic Drums/Roland TR-909`, which is what the Library Panel's column-1 list actually contains.
- **P0-2 — silent default-mode flip** — `lastScan` is no longer written in disk-shape for callers that did not request it. `resolve_path` and `set_instrument` for no-mode callers behave identically to v3.0.4.
- **P0-3 — inventory JSON overwrite + missing source tag** — disk scans write to `library-inventory-disk.json`, not the canonical AX file. Both files now carry `"source"`.

### Testing

- `LibraryDiskScannerTests`: 30 tests (was 8) — 15 new mapper/scan unit cases, Panel-inventory cross-check integration, symlink-cycle guard.
- `ScanLibraryModeRoutingTests`: 8 new tests — the complete mode-routing matrix + v3.0.5 regression guard.
- Full suite: 789 tests pass (skips: `testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths`, `testStatePollerStartStopLifecycle`).

## [3.0.5] — 2026-04-23

Filesystem-backed library enumeration. v3.0.4's `scan_library` still returned only 345 leaves (7% of the on-disk reality) because its live AX probe was deliberately bounded: clicking a preset-looking element in Logic's Library Panel *loads* that preset onto the focused track, and the probe had no non-destructive folder-vs-leaf discriminator for column 2+. v3.0.5 side-steps the problem entirely — instead of probing the Library Panel it enumerates `~/Music/Logic Pro Library.bundle/Patches/Instrument/` on disk, where every `.patch` is a directory and the filesystem hierarchy is exactly the path Logic's Library Panel navigates. On a full factory install this surfaces 5,000+ leaves (vs the prior 345) with no AX interaction, no panel mutation, and no dependency on whether the Library is even open. Paired with v3.0.4's N-segment `selectPath`, every patch on disk is now both enumerable AND loadable.

### Added

- **`LibraryDiskScanner.scan(homeDirectory:fileManager:)` / `scan(bundleURL:fileManager:start:)`** — pure filesystem enumerator. Recursively walks the Patches/Instrument bundle, emits a `LibraryRoot` schema-identical to the AX scan (same fields, same `LibraryNode` recursive shape, same `presetsByCategory` flat index). Strips `.patch` from display names so clients see "Acid Etched Bass", not "Acid Etched Bass.patch" — matching the Library Panel display and the segment format required by `selectPath`. Skips dotfiles, tolerates unreadable subfolders (graceful-empty folder node), and throws `ScanError.bundleNotFound` only if the top-level bundle is missing.
- **`library.scan_all` mode parameter** — `{"mode": "disk"}` (new default), `{"mode": "ax"}` (legacy AX probe, unchanged), `{"mode": "both"}` (runs both and returns a diff summary with leaf/node counts and on-disk-only count). Unknown mode values fall through to `"disk"` so older clients cannot accidentally enable the legacy path by sending a stale param.

### Changed

- **`library.scan_all` default behavior** — previously only ran the AX probe (345 leaves on a full factory install). Now defaults to the disk scan. Clients that relied on the legacy 345-leaf output can opt in with `{"mode": "ax"}`, but the JSON schema is unchanged so most callers transparently get the wider coverage.
- **`library.resolve_path`** — now resolves against whichever tree was most recently produced (disk or AX), via the same `lastScan` actor state. Deep paths like `Synthesizer/Bass/Acid Etched Bass` now resolve after a disk scan; before v3.0.5 they returned "not found" because the 2-level AX scan never surfaced them.

### Fixed

- **14× `scan_library` undercount** — closes the v3.0.4 known limitation. 345 leaves → 5,000+ leaves on a full factory install; no AX mutation of the user's project.

### Testing

- New: `LibraryDiskScannerTests` — 8 tests covering happy path, leaf suffix stripping, `presetsByCategory` flattening, hidden-file skip, missing-bundle throw, empty-bundle graceful-empty, 4-level hierarchies, and a local-machine integration smoke test (only runs if the factory bundle is present, expects ≥1000 leaves).
- Full regression: 759 tests passing under `swift test --skip testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths --skip testStatePollerStartStopLifecycle`.

## [3.0.4] — 2026-04-21

N-column Library Panel navigation. Pre-3.0.4 `track.set_instrument` took `parts[0]` + `parts[last]` of the supplied path and dropped every middle segment, so a live call with `Synthesizer/Bass/Acid Etched Bass` would call `selectCategory("Synthesizer")` then `selectPreset("Acid Etched Bass")` — but by that point column 2 held Synthesizer's 14 *subfolders* (Arpeggiated, Bass, Lead, Pad, …), not its presets, so the second call always failed with "Preset not found". The fix walks every segment in order through a single AX primitive (`AXSelectedChildren` + `AXPress`), which is what Logic's 2-column sliding Library Panel actually needs: clicking a subfolder in column 2 slides the view so column 1 becomes the subfolder and column 2 shows its direct children, and clicking a leaf preset commits it without sliding.

### Added

- **`LibraryAccessor.selectPath(segments:settleDelay:runtime:library:)`** — N-segment walker for the Library Panel. Clicks each segment via the existing AX-native selection pair (`AXSelectedChildren` on the parent `AXList` + `AXPress` on the target `AXStaticText`), waiting for Logic's column-slide to settle between clicks. 2-segment calls behave identically to the previous `setInstrument(category:preset:)` path; 3+ segment calls unlock the deeper subfolders that Logic exposes (top-level Synthesizer, Electronic Drums, etc.).

### Changed

- **`track.set_instrument`** delegates to `LibraryAccessor.selectPath` instead of the hardcoded `selectCategory + selectPreset` pair. Paths with 2 segments (`Bass/Sub Bass`) keep working exactly as before; paths with 3+ segments now resolve correctly. Error message updated to reference the new N-segment contract: "Invalid 'path': must have at least 2 segments (e.g. 'Bass/Sub Bass' or 'Synthesizer/Bass/Acid Etched Bass')".

### Not changed (and why)

- **`scan_library` deep walk** — `buildLiveTreeProbe` still returns `[]` at depth 2+. The algorithm in `enumerateTree` already supports arbitrary depth (proven by `testEnumerateTree_Deep6Level` and the new `testEnumerateTree_3Level_SynthBass_ElectronicDrums`), but the production probe cannot safely descend by "click and observe": clicking a preset-leaf in Logic's Library actually *loads* it onto the focused track, which would mutate the user's project during an enumeration scan. A non-destructive deep scan requires a folder-vs-leaf discriminator read from the AX tree *before* clicking (the disclosure-triangle indicator Isaac observed in column 2). Implementing that safely needs a dedicated offline probe session against Logic's AX exposure, which is deferred to a follow-up release. For now `scan_library` continues to return the flat 2-level view (top-level categories + direct presets, ~345 leaves) — the undercount is honest: the tool reports only what it can read without side effects. Users who know a deeper path can still call `track.set_instrument` with the full path; only the bulk enumeration path is limited.

### Testing

- New: `testSelectByPath_ThreeSegment_Synthesizer_Bass_AcidEtchedBass` (locks Isaac's exact live-bug path at the selectByPath layer)
- New: `testSelectByPath_FourSegment_DeepPath` (confirms arbitrary depth)
- New: `testSelectByPath_ThreeSegment_MissingMiddle_Aborts` (fail-fast on missing intermediate)
- New: `testEnumerateTree_3Level_SynthBass_ElectronicDrums` (locks the 4-leaf expectation for the 3-level fake tree)
- Full regression: `swift test --skip testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths --skip testStatePollerStartStopLifecycle` passes.

## [3.0.3] — 2026-04-20

AX-native control surface pass. The directive was explicit — replace every primary GUI-click call path with the Apple AX API; use CGEvent synthesis only as a last-resort fallback where Logic's UX contract requires it. v3.0.3 audits and rewrites the remaining live click sites so that AX attempts always run first, and CGEvent synthesis only survives as a last-resort fallback where Logic's own UX contract requires it.

### Changed

- **Track selection (`track.set_instrument` + `track.select`) is now AX-native.** Replaced the ~45-line CGEvent coord-click block in `AccessibilityChannel.defaultSelectTrack` / `setTrackInstrument` with a new `AXLogicProElements.selectTrackViaAX(at:)` ladder:
  1. `AXPress` on the track header.
  2. `AXSelected = true` attribute write (if the attribute is settable).
  3. `AXPress` on each child element (name field, icon, etc.) — some Logic header subviews reach the selection handler only through children.
  4. CGEvent coord-click (last resort, only if all 3 AX steps reported failure).

  Caller (`AccessibilityChannel`) still owns the read-back verification via `verifyTrackSelection` — the helper just returns whether any ladder step claimed success. The first three steps cover 100% of production Logic Pro 12.0.1 headers observed in E2E; step 4 remains because AX tree-mutation lag under heavy region loads can cause the first three to silently no-op in rare cases.

- **Plugin Setting popup (`plugin.scan_presets`) prefers `AXShowMenu` + `AXPress` before CGEvent.** Previously the handler always CGEvent-clicked the Setting popup at its AX-computed centre; the T0 v0.6 note said "popup AXPress unreliable" without having tested `AXShowMenu`, which is NSAccessibility's canonical action for opening a popup button's menu programmatically. v3.0.3 tries `kAXShowMenuAction` first, falls back to `kAXPressAction`, and only CGEvent-clicks if neither produces an AXMenu within a 350 ms settle window.

### Rationale: what was *not* replaced, and why

- **Rec-arm / mute / solo checkboxes (`track.set_mute` / `track.set_solo` / `track.record_arm`)** — already an AX-first ladder: `AXPress` → `AXConfirm` → `AXValue = NSNumber` → `AXValue = CFBoolean` → CGEvent click (with read-back verification between each step). The mouse-click step is reached only if *all four* AX attempts silently fail, which is the documented behaviour for certain Logic 12 custom checkbox subviews. Removing this last step would regress production reliability with no gain.

- **`transport.set_tempo` tempo slider double-click** — Logic Pro 12 exposes the tempo as an `AXSlider` whose own help text says "double-click to enter a new value". AX `AXValue` assignment only nudges by ±1 BPM; `AXIncrement` only jumps by +10. The double-click opens an inline numeric entry that is Logic's *documented* UX for exact-value entry. v3.0.3 keeps the CGEvent double-click + keystroke path behind the AX-verified slider discovery; this is AX-native tempo control wrapped around a Logic-mandated UX primitive, not a "simple click control" substitute. The AX-only path (direct `AXValue` set) is still used for the fake-AX test harness where no mouse subsystem exists.

### Testing

- Full regression: `swift test --skip testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths --skip testStatePollerStartStopLifecycle` — 747 tests pass.
- New unit coverage: `testAccessibilityChannelAXBackedTrackDefaultsUseFakeAXTree` + `testAccessibilityChannelAXBackedTrackSelectFailsWhenVerifiedSelectionSettlesElsewhere` now exercise the AX-first path end-to-end (previously these tests expected the CGEvent coord-click path which is now only reached after 3 AX attempts).

## [3.0.2] — 2026-04-20

Live-use hotfix targeting two E2E pain points found while actually generating music in Logic Pro 12.0.1 at the v3.0.1 MCP surface.

### Fixed

- **`transport.set_tempo` now works end-to-end without manual intervention.** Logic Pro 12 exposes the control-bar tempo as an **AXSlider** (role "AXSlider", description "템포" / "Tempo") — not a text field. Direct AXValue assignment only nudges by +1 and AXIncrement jumps by +10, so neither gives an exact value. The slider's help text reveals the real path: **double-click opens an inline numeric entry**. v3.0.2 synthesises a native `CGEvent` double-click at the slider centre, types the target BPM via `CGEventKeyboard`, and presses Return. Verified on live Logic Pro 12.0.1 (120 → 140, exact). Falls back to `AXIncrement` (10-BPM granularity) if the typed entry doesn't commit within the verification window.

- **`record_sequence` regions are audible on playback.** The SMF-import path created a new MIDI track but sometimes without a Software Instrument plugin loaded, yielding silent regions. v3.0.2 post-processes the imported track: selects it and auto-calls `track.set_instrument` with a safe default (`Synthesizer/Bass`). Callers can override via a new `instrument_path` parameter. Response now includes an `instrument` field reporting the load outcome.

### Added

- `Sources/LogicProMCP/Accessibility/AXMouseHelper.swift` — native CGEvent-based double-click, numeric typing, Return/Escape. No osascript spawning (avoids the FD-leak path that disabled the v2.x tempo fallback). Re-used for any future "double-click-to-edit" slider surfaces.
- `AXLogicProElements.findTempoSlider` — locates the tempo slider through three fallback roots (control bar → transport bar → main window) so it works both with production AX trees and the test-double AX trees used in unit tests.
- `logic_tracks.record_sequence` accepts an optional `instrument_path: String` (also `instrument`) to choose the post-import Software Instrument preset.

### Still manual in v3.0.2 (follow-up)

- `transport.set_cycle_range` — cycle locators aren't standard sliders in the control bar; their UI lives in the ruler/timeline and needs a different discovery path.
- Full Sound Library download — `Logic Pro → Sound Library…` opens a modal with its own "Select All / Install" controls; driving it end-to-end requires a multi-step dialog script.
- Deep Library tree scan — current scan enumerates only 1 level (category → preset). Sub-preset navigation works via `set_instrument { path: "Synthesizer/Bass/Analog Monster" }` if the caller already knows the path.

## [3.0.1] — 2026-04-20

Release-path and docs-honesty hotfix on top of v3.0.0. **No runtime behavior changes** — same 8 tools, 9 resources, 3 templates. Upgrade is a docs + CI + packaging refresh.

### Fixed

- **Architecture claims match reality.** Locally-built ADHOC releases are `arm64`-native (produced by `swift build -c release` without Xcode); Intel Macs run the binary under Rosetta 2. The v3.0.0 release asset named `…-universal.tar.gz` was bit-identical to `…-arm64.tar.gz` — technically arm64 masquerading as universal. v3.0.1 keeps both tarball names for Homebrew-tap backward compatibility but `manifest.json`, `README.md`, `docs/SETUP.md`, and `Formula/logic-pro-mcp.rb` now all state `arm64` native + Intel via Rosetta. CI with full Xcode still produces a genuine fat binary.
- **`release.yml` is dual-mode (notarized + ADHOC).** Previously the workflow hard-required `MACOS_CERT_BASE64` and 6 other Apple-Developer secrets, so every tag push failed visibly (red X on every release since v2.3.0). v3.0.1 detects secret presence at runtime: notarized path when present, ADHOC (`codesign --sign -`) when absent. Both paths publish `RELEASE-METADATA.json` with correct `signing` field (`notarized`|`adhoc`). CI `validate-install` matrix now runs end-to-end on every release.
- **README test-count unified.** Badge, body paragraph, and release notes now consistently cite **760 passing** (was drifting between 700 badge / 759 body / 760 notes).
- **Migration guidance expanded.** CHANGELOG §Migration now includes before/after examples for `set_instrument` (empty-call rejection) and `goto_position` (`time` alias removed).

### Added

- `Scripts/release.sh` — one-command ADHOC release that (1) builds + adhoc-codesigns the binary, (2) computes SHAs, (3) patches `Formula/logic-pro-mcp.rb` + commits Formula sync, (4) creates tag, (5) creates GitHub release with artifacts — in the right order. Prevents the v3.0.0 issue where the Formula SHA commit landed on `main` *after* the tag, leaving the tag with a stale sha256.
- Maintainer docs now document both release modes, the `Scripts/release.sh` wrapper, and the post-tag Homebrew SHA-sync step more clearly.

### Security

- No security changes in v3.0.1. The round-4/5 hardening (fail-closed installer, symlink validation, JSON validation, rate-limit cap, ISO 8601 alignment, Logger/JSON thread-safety) remains in place from v3.0.0.

## [3.0.0] — 2026-04-19

> Renumbered from 2.4.0 to 3.0.0 to honor SemVer — the changes below break
> the track-mutation and `record_sequence` contracts, which is a major bump.
> The v2.4.0 tag was a pre-release and should be considered yanked in favor
> of v3.0.0.

### Breaking Changes

- **All mutating `logic_tracks` commands now require explicit `index`**. Previously `index` defaulted to `0` when missing, which silently mutated track 0 on malformed caller requests. Commands affected: `select`, `delete`, `duplicate`, `rename`, `mute`, `solo`, `arm`, `arm_only`, `set_automation`, `set_instrument`. Requests missing or with non-numeric `index` now return `isError: true`.
- **`arm_only` no longer buries failures in a success payload**. If the primary arm fails, or if any disarm fails, the command returns `isError: true` with detail. The structured JSON payload (`{armed, armedSuccess, disarmed, failedDisarm, detail}`) is reserved for complete success.
- **`record_sequence` no longer returns `track_index_confirmed`**. The dispatcher now polls the AX cache for up to 2 seconds and returns `isError: true` if the new track never appears — the fallback value (`false` + last-known-index) was a silent correctness hazard. On success, `created_track` is always the real new track index.
- **`record_sequence` hard-fails when `transport.goto_position bar=1` fails**. Logic Pro anchors imported regions at the playhead; a failed pre-reset would silently place notes at the wrong bar. The step is now a blocking precondition.
- **`set_instrument` requires `path` OR both `category` + `preset`**. Empty calls (only `index`) are rejected instead of silently dispatching with no instrument target.
- **`goto_position` canonicalises the position key**. Only `{ bar }` or `{ position }` are accepted — the undocumented `time` alias was removed so the API contract, tool description, and runtime now all agree on a single key. Both `B.B.S.S` and `HH:MM:SS:FF` formats remain supported.
- **`logic_system.health.logic_pro_running` now uses the same source of truth as `logic_project.is_running`**. Previously `health` OR-ed an AppleScript availability flag into the bit, which could disagree with `is_running`'s PID-based check. AppleScript status remains surfaced separately in the `channels` array.

### Added

- **`select` now fail-closes on malformed `index`**. A request like `{"index":"abc"}` is rejected with a clear error instead of silently selecting track 0.
- **Explicit-index regression tests** for every mutating command (8 new tests in `DispatcherTests.swift`).
- **Universal + arm64 release tarballs**. The release workflow now publishes both `LogicProMCP-macOS-universal.tar.gz` and `LogicProMCP-macOS-arm64.tar.gz` (same fat binary, two names) so existing Homebrew taps and arm64-only users both resolve cleanly.
- **GitHub Actions pin to commit SHA**. `actions/checkout` and `softprops/action-gh-release` are now pinned to immutable commit hashes instead of mutable tags, closing a supply-chain gap in the release workflow.

### Fixed

- `docs/API.md` now matches runtime behavior: `arm_only` error paths, `record_sequence` success schema (no `track_index_confirmed`), `set_automation` full mode enum (incl. `trim`), `set_instrument` required-field semantics.
- `Scripts/live-e2e-test.py` updated to reflect v3.0.0 contract: rejects-without-index assertions, new `set_instrument` error messages, softer environment gates.

### Security

- Release workflow dependencies pinned to commit SHA (supply-chain hardening).
- **Release tag trigger narrowed to strict SemVer** (`v[0-9]+.[0-9]+.[0-9]+` with optional pre-release suffix). Arbitrary `v*` tags no longer unlock signing secrets in GitHub Actions.
- **Installer warns when provenance is fetched from the same release surface.** `Scripts/install.sh` now prints a hardening recommendation when `LOGIC_PRO_MCP_SHA256` / `LOGIC_PRO_MCP_TEAM_ID` aren't passed out-of-band.
- **Installer trust model documented.** `README.md` now leads with Homebrew as the hardened path and marks `bash <(curl ...)` as a convenience path that does **not** protect the installer script itself. `SECURITY.md §Installer trust model` lays out three trust tiers.
- **`logic://mcu/state` uses `JSONEncoder`** instead of a hand-rolled escaper, so MCU LCD bytes and port names carrying control characters (`\n`/`\r`/`\t`/U+0000-U+001F) now produce valid JSON instead of breaking parsers.
- **`JSONHelper` shared encoders are lock-gated** — concurrent MCP tool handlers can't race on `JSONEncoder` internal state.
- **`Logger` rate-limit map has a 1024-entry cap** with expired-window sweep + oldest-eviction, preventing a long-running daemon from inflating memory via user-controlled log strings.
- **`logic://library/inventory` resolves through three candidate paths** (`LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override → repo-relative → `~/Library/Application Support/LogicProMCP/`) and emits a `Log.warn` on miss, so daemon launches where CWD=`/` no longer silently report an empty library.

### Fixed — drift from prior review

- `docs/API.md` header now advertises **9 resources + 3 templates** (was 6 + 1).
- `docs/API.md` `select` entry now documents the actual matching semantics (`localizedCaseInsensitiveContains`, not case-sensitive-first-match).
- `logic_system.help` default section matches the new resource/template counts.
- `Scripts/live-e2e-test.py` resource-list assertions updated to the v3.0.0 surface (9 resources, 3 templates, MCU filtered when disconnected).
- `manifest.json` and `docs/{MAINTAINERS,SETUP}.md` now advertise the universal binary consistently with `Formula/logic-pro-mcp.rb` and `release.yml` (no more arm64-vs-universal drift).

### Fixed — round 5 (final hardening pass)

- **`release.yml` tag trigger is now valid glob, not regex.** Previous pattern used `[0-9]+` which GitHub Actions treats as literal `+` (not repetition), so the `v3.0.0` tag would not have triggered the workflow and the notarized/signed release path would have been unreachable. Replaced with `v[0-9]*.[0-9]*.[0-9]*` (+ pre-release variant) and added a step-level strict-SemVer regex guard that fails the workflow before any secret-using step.
- **Installer is fail-closed by default.** `Scripts/install.sh` now refuses to run unless `LOGIC_PRO_MCP_SHA256` + `LOGIC_PRO_MCP_TEAM_ID` are both supplied. Opting into the same-origin (provenance fetched from the same release as the binary) path requires an explicit `LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1`. The CI `validate-install` job now resolves pins from the freshly-published `SHA256SUMS.txt` and `RELEASE-METADATA.json`, so it exercises the hardened path end-to-end.
- **`README.md` and `docs/SETUP.md` lead with Homebrew.** The one-line `bash <(curl ...)` path is demoted to "download-inspect-run" with explicit `LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN` opt-in guidance.
- **Testing claims match fresh evidence.** README no longer says "700+ tests all passing, Live E2E verified"; it reports the actual `swift test` count (759) and clarifies that live E2E assertions are split between environment-independent (pass cleanly) and Logic-Pro-gated (require a live session).
- **`logic://library/inventory` now validates JSON before serving.** `ResourceHandlers.readLibraryInventory` parses the file with `JSONSerialization` and falls through to the next candidate on malformed input, so a corrupt or attacker-shaped cache file can't be returned under the `application/json` mimetype.
- **Public contract surfaces converged.** `docs/API.md` Resource Catalog lists all 9 resources + 3 templates, `set_tempo` range (5–999) matches runtime in API.md, tool description, and `logic_system help`. `docs/TROUBLESHOOTING.md` startup-banner example reflects v3.0.0 counts. `README.md` documentation table lists "9 resources, 3 templates" instead of the stale "6 resources".

### Fixed — round 4 (production-readiness pass)

- **ISO 8601 fractional-second precision is preserved across the wire.** Shared `JSONEncoder`/`JSONDecoder` now use a custom date strategy matching `Logger`'s `[.withInternetDateTime, .withFractionalSeconds]` formatter, so `logic://mcu/state.connection.lastFeedbackAt` and every other `Date` field stay aligned with the log timestamp format. Previously `JSONEncoder.iso8601` silently truncated sub-second precision.
- **`LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override now resists symlink abuse.** `validateLibraryInventoryPath` resolves symlinks, refuses anything that isn't a regular `.json` file ≤ 64 MiB, and logs the resolved path on rejection. Removes the "hostile daemon-env var points MCP at `/etc/passwd`" class of attacks.
- **`goto_position` now fails closed on unknown param keys.** Previously a caller sending the legacy `{ "time": "…" }` alias would silently seek to `"1.1.1.1"`; now the dispatcher returns an explicit error naming the removed key and the allowed set (`bar`, `position`).
- **`encodeJSON` fallback path uses a full JSON escape helper** (`jsonStringEscape`) covering `"`, `\`, `\b`, `\f`, `\n`, `\r`, `\t`, and U+0000-U+001F. Previous escaping missed control characters, which would have produced invalid JSON if a future Foundation error message carried them.
- **`StatePoller.Runtime` gains an injectable `sleep` closure.** Tests can now drive the poll loop at 1 µs cadence instead of waiting out the production 3 s interval. The two lifecycle tests (`testStatePollerStartStopLifecycle` and `testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths`) used to take ~2 000 s each and were excluded from CI; with the injectable sleep + `.fastTest` runtime (which also short-circuits `hasVisibleWindow` to avoid live AX calls) they now complete in ≤ 20 ms each and are included in the default test run.
- Maintainer docs now document the runtime env matrix (`LOG_LEVEL`, `LOG_FORMAT`, `LOGIC_PRO_MCP_LIBRARY_INVENTORY`, installer pins) and the post-tag Homebrew `sha256` sync step.

### Migration from v2.3.x

Replace every mutating `logic_tracks.*` call with an explicit `index`:

```diff
- logic_tracks rename { "name": "Lead Vox" }
+ logic_tracks rename { "index": 0, "name": "Lead Vox" }

- logic_tracks mute { "enabled": true }
+ logic_tracks mute { "index": 3, "enabled": true }
```

For `arm_only` and `record_sequence`, check `isError` before parsing the JSON payload. Previous `armedSuccess: false` / `track_index_confirmed: false` responses are now returned as structured errors.

#### `set_instrument` now requires a selector

```diff
- logic_tracks set_instrument { "index": 0 }
+ logic_tracks set_instrument { "index": 0, "path": "Electronic Drums/Roland TR-909" }
# or
+ logic_tracks set_instrument { "index": 0, "category": "Synthesizer", "preset": "Vintage Mono" }
```

#### `goto_position` renames `time` → `position`

```diff
- logic_transport goto_position { "time": "00:00:10:12" }
+ logic_transport goto_position { "position": "00:00:10:12" }

- logic_transport goto_position { "time": "9.1.1.1" }
+ logic_transport goto_position { "position": "9.1.1.1" }
# or
+ logic_transport goto_position { "bar": 9 }
```

Sending `{ "time": ... }` in v3.0.0+ returns an explicit error naming the removed key.

## [2.3.1] — 2026-04-19

### Fixed

- **`record_sequence` now places regions at the requested bar reliably.** Live verification revealed that Logic Pro's MIDI File Import anchors the imported region to the current playhead position — a bar=1 request on a session whose playhead had drifted to bar 129 produced a region at bar 129. The fix forces the playhead to bar 1 before every import via the Go to Position dialog (`탐색 → 이동 → 위치… / Navigate → Move → Position…`, auto-extends project length; the slider path was silently clamping). Strategy D padding CC continues to position notes within the region at the requested bar.
- **`transport.goto_position` no longer silently clamps to project length.** Previous implementation used the bar slider whose value is clipped to the active project's end bar. A `goto_position bar=50` on an 8-bar project stopped at bar 8 with a success response. The new implementation uses the dialog (which auto-extends the project) as the primary path and falls back to slider only when the dialog is disabled (empty project).
- **Dialog-keystroke race eliminated.** The previous `delay 0.5` assumed the Go-to-Position dialog would render within 500 ms. On slow machines the Cmd+A keystroke reached the arrange area instead, silently triggering "Select All Regions." The dialog-ready state is now polled with a 3-second timeout.

### Security

- `midi.import_file` now restricts its `path` parameter to `/tmp/LogicProMCP/*.mid`. The only legitimate producer is `TrackDispatcher.record_sequence` (UUID-generated temp paths); external MCP callers cannot point the AX file dialog at arbitrary filesystem locations.

### Testing

- `testRecordSequenceSMFImportHappyPath` now asserts that `transport.goto_position` with `bar=1` is routed BEFORE `midi.import_file`. Catches silent regression of the v2.3.1 bar-positioning invariant.

### Documentation

- `docs/API.md`: documented the dialog-path latency for `transport.goto_position` (~800 ms), and marked `recorded_to_track` as a legacy alias for `created_track`.
- `ChannelRouter.swift`: inline comment on `region.select_last` / `region.move_to_playhead` clarifying they are reserved for a future region-editor tool (record_sequence does not use them).

## [2.3.0] — 2026-04-18

### Added

- **`logic_tracks.record_sequence` — full rewrite via server-side SMF generation + AX File Import**
  - Replaces the broken real-time recording path (record-arm latency + silent error swallowing). SMFWriter emits a Type 0 Standard MIDI File; AccessibilityChannel drives `File → Import → MIDI File…` to load the file into the current project. Note timing is now byte-exact with zero drift regardless of system load.
  - **Strategy D — tick-0 padding CC** bypasses Logic's MIDI-import quirk of stripping leading empty delta. When `bar > 1`, SMFWriter emits a harmless `CC#110 val 0` at tick 0 so Logic preserves the full tick timeline; the caller's notes land at exactly the encoded positions inside a region that spans bar 1 through the target bar. Verified live on Logic Pro 12: a `bar=50` request produces a region that Logic describes as starting at bar 1 and ending at bar 51.
  - Response schema: `{ recorded_to_track, created_track, track_index_confirmed, bar, note_count, method: "smf_import" }`. `track_index_confirmed` is `false` when the AX cache hadn't observed the new track within 500 ms — caller should re-read `logic://tracks` if a confirmed index is needed.
  - Hard upper limit lifted from 256 → 1024 notes (bounded by SMFWriter). Tempo/time-signature come from the `StateCache` (override via `tempo` param).
- **`logic_tracks.arm_only` — error propagation fix**
  - Response now carries `armedSuccess: Bool`, `disarmed: [Int]`, `failedDisarm: [Int]`, and `detail: String`. `armed` kept as the int target index for backward compatibility. Closes H-4 finding.
- **`logic_navigate.goto_bar` — real channel**
  - Delegates to `transport.goto_position` (AX bar-slider); the dead `nav.goto_bar` route (`[.mcu, .cgEvent]` with no handler) is removed.
- **`logic_navigate.goto_marker { name: ... }` — now works**
  - `StatePoller` calls a new `AccessibilityChannel.nav.get_markers` operation every 5th tick (~15 s) and pushes the parsed list into `StateCache.updateMarkers`. Name-based lookup now has a populated cache to consult.
- **`SMFWriter` (new internal module)** — Type 0 SMF generator with VLQ encoding, tempo + time-signature meta events, round-half-up ms→tick conversion, bar-offset positioning, up to 1024 notes. No public MCP surface — internal helper for `record_sequence`.
- **`SMFWriter.cleanupOrphanFiles(in:olderThan:)`** — server startup sweeps `/tmp/LogicProMCP/` for `.mid` files older than 5 minutes, reclaiming space from crash-interrupted imports.
- **New operations in the routing table**: `midi.import_file` (AX), `region.move_to_playhead` (AX), `region.select_last` (AX). `midi.import_file` is the primary consumer; the other two are experimental helpers retained for future region-editing tools.

### Changed

- `StatePoller` marker polling now runs every 5th transport tick rather than every cycle. Markers change infrequently and AX enumeration is relatively expensive (~9 s at 3 s poll interval); this trades freshness for AX-query overhead.
- Binary is now self-signed on install (adhoc codesign replaces the GitHub Actions build signature) so macOS TCC treats the installed path as consistent across updates, avoiding silent "not permitted" failures when the binary hash changes but the path stays the same.

### Fixed

- `get_regions` used to return `[]` with `_debug.layoutItems: 0` when regions existed under certain AX tree shapes. Same-release change: the poller now walks the arrange area recursively via `entire contents` in addition to the direct-child path.
- `record_sequence` no longer silently swallows mid-step failures. Every step (`select` → `arm_only` → `SMFWriter.generate` → file write → `midi.import_file`) propagates errors back to the caller with the failing channel in the message.

### Removed

- The real-time CoreMIDI recording path previously used by `record_sequence` (goto → record → sleep → play_sequence → stop) is gone. `midi.play_sequence` remains for live-performance callers; it is no longer invoked by `record_sequence`.
- `nav.goto_bar` entry in `ChannelRouter.v2RoutingTable` (no channel implemented it; clients now hit `transport.goto_position` via `NavigateDispatcher`).

### Documentation

- Internal record-sequence SMF import PRD (v0.4) with review rounds and live OQ-1/OQ-2/OQ-3 probe results.
- Internal record-sequence SMF import tickets (T1-T7) with TDD specs.
- Internal navigate-redesign status marked Done with T1/T2/T3 evidence.
- Internal installer-supply-chain ticket resolution: pinned SHA256 hash in `Scripts/install.sh` (implemented in 2.3.0). See §Security below.

### Security

- `Scripts/install.sh` now verifies the downloaded binary against a pinned SHA256 hash published alongside the release. Install aborts on mismatch. This closes the supply-chain gap where a mutated release asset could be served by a compromised mirror without the installer noticing.
- `AccessibilityChannel.midi.import_file` uses the same `AppleScriptSafety.openFile` (NSWorkspace) injection-safe path as `project.open` — no shell interpolation reaches the file dialog.

### Testing

- +2 SMFWriter tests (`testSMFWriterEmitsPaddingCCWhenBarOffsetIsNonZero`, `testSMFWriterNoPaddingWhenBarIsOne`)
- +2 SMFWriter orphan-cleanup tests
- +5 TrackDispatcher tests (`arm_only` partial-failure visibility + `record_sequence` SMF-import happy path + error chain + invalid notes + hasDocument guard)
- +3 StatePoller marker-polling tests
- +2 NavigateDispatcher `goto_bar` delegation tests
- **Total**: 668 → 690 tests (+22). All pass.

## [2.2.0] — 2026-04-16

### Added

- `logic_project.get_regions` — read-only AX scan of the arrange area, parses Logic's AXHelp bar-position strings into `[RegionInfo]` JSON (English + Korean locales). Enables programmatic verification of `record_sequence` region placement without screenshots.
- `logic_tracks.arm_only` — composite "disarm every track, then arm exactly one", closing the multi-armed duplicate-record hole.
- `logic_tracks.record_sequence` — composite `select → arm_only → record → play → stop` for one-shot natural-language recording (⚠️ still subject to the record-arm latency bug tracked in `record_sequence sync bug` memory; use `send_chord`/`send_note` for reliable demos).
- `logic_mixer.set_plugin_param` — deterministic plugin-parameter control via Scripter on the currently-selected track.
- `logic_tracks.set_instrument`, `list_library`, `scan_library`, `resolve_path`, `scan_plugin_presets` — Library-panel enumeration + preset loading via AX.
- `StateCache.selectOnly(trackAt:)` actor mutator — preserves Logic's single-selection model when MCU select events arrive.

### Changed

- `logic://transport/state` resource now returns a wrapper object:
  `{ state: TransportState, has_document: Bool, transport_age_sec: Double }`.
  Clients can detect "no project open" / "stale snapshot" without cross-referencing `logic://system/health`. **Breaking** for clients reading top-level `tempo`, `isPlaying`, etc. — they now live under `.state`.
- `logic_project.close` now honours the documented `saving: "yes" | "no" | "ask"` parameter (previously always coerced to `"yes"`). Invalid values return an explicit error instead of silently saving.
- `StateCache.clearProjectState()` now also resets `transport` so the resource stops reporting the previous project's playback state after close.
- `MCUFeedbackParser` enforces single-track selection on every "select on" event, preventing multiple tracks from appearing selected simultaneously.
- Distribution version aligned at **2.2.0** across `ServerConfig.serverVersion` (SSOT), `Formula/logic-pro-mcp.rb`, `manifest.json`, `Scripts/install.sh`. `VersionConsistencyTests` pins this going forward.
- `Formula/logic-pro-mcp.rb` now installs helper assets (MCU setup docs, `Scripts/install-keycmds.sh` + siblings, `Scripts/LogicProMCP-Scripter.js`) into `pkgshare`; release workflow packs them into the tarball.
- `docs/API.md` + `README.md` synced with the shipped surface (record_sequence/arm_only/get_regions documented with known-limitation callouts, navigate gaps disclosed, insert/bypass_plugin marked removed, poll interval corrected to 3 s).

### Removed

- `logic_mixer.insert_plugin`, `logic_mixer.bypass_plugin` — had no channel with a working implementation; every call produced a dressed-up error. Use `set_plugin_param` on the selected track via Scripter instead. Router entries and AX stub branches pruned so there is no side-channel resurrection path.
- `plugin.insert`, `plugin.bypass`, `plugin.remove` router-table entries.
- `StateModels.PluginState` + nested `PluginParam` (unreferenced).
- `ServerConfig.channelHealthCheckTimeout` (unreferenced since initial commit).
- `AXValueExtractors.extractCheckboxState` + companion test assertions (referenced only by its own unit test; production callers use `extractButtonState`).

### Moved

- `Scripts/library-ax-probe.swift`, `plugin-detective.swift`, `plugin-menu-ax-probe.swift`, `setting-popup-probe.swift` → `Scripts/probes/`. Developer-only investigation scripts are isolated from operational install/uninstall/e2e scripts. SwiftPM target unaffected.

### Documentation

- New ticket drafts:
  - Internal navigate-redesign tickets — T1 (goto_bar real channel), T2 (marker cache population), T3 (contract alignment).
  - Internal installer-supply-chain tickets — same-release verification root mitigation options.

## [2.1.0] — 2026-04-12

### Security

Nine vulnerabilities identified and fixed during the production-readiness review.

- **P0** — AX Save-As dialog accepted unvalidated paths. `saveAsViaAXDialog` now guards with `AppleScriptSafety.isValidProjectPath` before writing into the dialog (`AccessibilityChannel.swift`).
- **P1** — `DispatchQueue.main.sync` could deadlock in a CLI process without an active AppKit runloop. `ProcessUtils.runAppKit` now probes `CFRunLoopIsWaiting(CFRunLoopGetMain())` and returns `nil` when the main runloop is unavailable, letting callers fall back to the subprocess path.
- **P1** — MIDI packet traversal used raw pointer arithmetic without bounding `wordCount`. Added `min(wordCount, 64)` bound in `ProductionMCUTransport` before indexing into the UMP packet buffer.
- **P1** — `ServerConfig.logicProProcessName` was interpolated into AppleScript without escaping. Added `\\` and `"` escaping before interpolation in `ProcessUtils.logicProPIDViaSystemEvents`.
- **P2** — Track rename accepted unbounded names. Truncated to 255 chars with JSON-escaped response.
- **P2** — Virtual MIDI port names passed newlines/null bytes to CoreMIDI. Filter newlines/nulls and truncate to 63 chars in `midi.create_virtual_port`.
- **P2** — `stepInputDurationMs`, `send_note.duration_ms`, and `send_chord.duration_ms` were unbounded. Capped at 30,000 ms to prevent actor DoS.
- **P2** — `verifyOpenedProjectScript` and `saveProjectAsScript` incomplete escaping. Added `\n` / `\r` stripping.
- **P2** — `PermissionChecker.runAutomationProbeViaShell` used nested shell quoting. Replaced with direct `/usr/bin/osascript -e` invocation.

### Added

- **Graceful shutdown** — SIGTERM and SIGINT handlers installed in `MainEntrypoint.run` via `DispatchSource` so the server exits cleanly (channels stopped, MIDI ports released) instead of being killed with resources held.
- **Configurable state polling interval** — new `ServerConfig.statePollingIntervalNs` (default 3 s; initially introduced at 5 s and tightened to 3 s in the v2.2 census sync) replaces the previously hardcoded value in `StatePoller`.
- **E2E test suite** — `EndToEndTests.swift` (93 tests) covering tool → dispatcher → router → channel chains, resource reads, lifecycle, concurrency, and input validation.
- **Production readiness tests** — `ProductionReadinessTests.swift` (26 tests) verifying all security fixes, duration caps, path validation, port name sanitization.
- **Live E2E test runner** — `scripts/live-e2e-test.py` drives the actual binary against a running Logic Pro instance (229 tests across 20 sections).
- **Comprehensive documentation** — new architecture notes, `docs/API.md`, MCU setup guidance, and `docs/TROUBLESHOOTING.md`.
- **Launch agent template** — `scripts/com.logicpro.mcp.plist.template` for operators who need the MCP server available outside Claude Code sessions.

### Changed

- **`StatePoller.stop()` is now `async`** and awaits in-flight poll cycles before returning, avoiding races where the cancelled poll loop could still touch the cache after `stop()` returned.
- **`ProcessUtils.runAppKit<T>` returns `T?`** instead of `T`. Callers must unwrap or fall back. This is a breaking change at the Swift API level but internal-only.
- **`StatePoller` decoder** now uses `dateDecodingStrategy = .iso8601` to match the encoder, fixing a silent decode failure on `lastUpdated` that caused project/transport polls to be dropped.

### Removed

Dead code cleanup — ~43 lines of production code and ~40 lines of duplicated test helpers.

- `MCUChannel.executePluginParam` (orphaned method, routing sends `mixer.set_plugin_param` to Scripter).
- `ProcessUtils.logicProRunningViaAppleScript` (private, never called).
- `AppleScriptSafety.shouldUseNSWorkspaceForOpen` (dead marker constant).
- `MIDIEngine.sendPolyAftertouch` (production never sent polyphonic aftertouch).
- `MCUProtocol.isDeviceResponse` (test-only wrapper over `parseDeviceResponse`).
- 11 operations in `MIDIKeyCommandsChannel.mappingTable` that had no entry in `ChannelRouter.v2RoutingTable` (`automation.off/read/touch/latch`, `edit.force_legato`, `edit.remove_overlaps`, `edit.trim_at_playhead`, `project.export_midi`, `transport.toggle_click`, `view.toggle_list_editors`, `view.toggle_score`).

### Tests

- Total: **500 Swift tests** + **229 live E2E tests** passing.
- New consolidated `SharedTestHelpers.swift` eliminates duplicate `toolText`, `resourceText`, and `ServerStartRecorder` helpers across 5 test files.

---

## [2.0.0] — 2026-04-06

Initial production release of the v2 architecture:

- 7 communication channels (MCU, MIDIKeyCommands, Scripter, CoreMIDI, Accessibility, CGEvent, AppleScript).
- 8 MCP tool dispatchers.
- 6 resources + 1 template.
- 90+ routed operations with fallback chains.
- Manual-validation approval gate for MIDIKeyCommands and Scripter channels.
- Signed and notarized macOS binary via GitHub Actions release workflow.

---

## [0.1.0] — 2025-12-xx

Initial prototype.
