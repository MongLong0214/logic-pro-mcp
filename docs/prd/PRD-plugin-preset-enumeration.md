# PRD: Plugin Preset Full Enumeration + Path-Addressed Load (F2)

**Version**: 0.6
**Author**: Isaac (via Claude Opus 4.6)
**Date**: 2026-04-13
**Status**: Approved (T0 spike completed live — empirical findings folded in; verdict MIXED)
**Size**: XL

### Changelog
- **0.6** (T0 spike empirical findings — see `docs/spikes/F2-T0-plugin-menu-probe-result.md`): Verdict **MIXED**. Key corrections: (a) **Setting dropdown role = `AXPopUpButton`** (NOT `AXMenuButton` — the AXMenuButton in plugin window is View-mode toggle), (b) **CGEvent click required for Setting popup open** (popup AXPress returns `-25204 .cannotComplete` despite UI effect — unreliable), (c) **AXPress on AXMenuItem 100% reliable** for menu navigation (verified: 11 hierarchical submenus populate after press), (d) **Plugin identity via AU registry only** — `AXIdentifier`/`AXDescription` are nil; `AXTitle` is patch name not plugin name (e.g. "Acoustic Guitar" patch shown when ES2 loaded). Plugin name "ES2" exists as `AXStaticText` within window at fixed position. (e) Empirical `submenuOpenDelayMs` floor lowered to **250 ms** (was 300 ms). (f) E11b severity upgraded to **P0 unconditional** (Post-Event permission required for CGEvent popup-open, no longer conditional). (g) `productionMouseClickDelegate` closure on `PluginWindowRuntime` is **REQUIRED**, not conditional. (h) `findSettingDropdown` heuristic: walk window children for `AXPopUpButton` whose `value` contains `"Preset"` / `"프리셋"` / `"Default"`.
- **0.5** (Round 4 + final Ralph polish): Editorial convergence — removes contradictions between normative ACs and edge-case/test descriptions. (a) E32 rewritten to match AC-3.0 algorithm exactly (cache-miss on `liveBundleID` lookup — removes "path's implied plugin" remnant), (b) E22 aligned with AC-2.3 — nil version always forces rescan; contentHash never used as skip-guard, (c) §8.2 integration test "cache hit with version nil but contentHash match → no AX" replaced with "version nil → rescan forced", (d) E31 cache key fallback uses `AXIdentifier` (locale-invariant AX equivalent of bundle ID) OR errors out — `AXDescription` removed from fallback key (would localize), `contentHash` removed from key construction (would mutate), (e) E32 error message shape corrected to match what AC-3.0 step (d) actually produces, (f) §4.4 Cache validity decision row + §10.2 risk row updated to remove residual "contentHash skip-guard" language — both now match AC-2.3/E22 prohibition (contentHash post-rescan only, never as skip-guard). Round 5 boomer ZERO residuals (Ralph convergence complete).
- **0.4** (Round 3 response): Addresses 1 P0 + 3 P1 + 2 P2 from Round 3. Key technical corrections: (a) **AU version source corrected** — `AudioComponentCopyName` returns a name string, NOT a URL; the correct zero-instantiation path is `AudioComponentGetVersion(audioComponent, &version)` (free function, not to be confused with `AUPlugInGetVersionNumber` which requires an instance) with `AVAudioUnitComponent.versionString` / `.componentURL` + `Bundle(url:).infoDictionary["CFBundleShortVersionString"]` as human-readable alternative, (b) `AXUIElementSendable` declared as **NEW** wrapper this PRD introduces (no F1 predecessor), with concrete `final class @unchecked Sendable` shape, (c) **AC-3.0 gate rewritten** — uses live `bundleID` from `identifyPlugin(in: window)` as sole comparator against `pluginPresetCache[liveBundleID]`; "path implies plugin" framing removed as ambiguous, (d) `ScannerWindowRecord` keyed by **`CGWindowID`** (stable integer, survives AX GC) as primary; `(bundleID, windowTitle)` pair demoted to fallback for rare unavailable-CGWindowID case, (e) AC-2.3 **nil-version rescan semantics**: when cached `pluginVersion` is nil, `skipAlreadyCached` treats entry as stale (contentHash is stored from prior scan, cannot be validated without re-scanning — the circular check is forbidden); force rescan on identifier match + nil version, (f) §10.2 risk row ledger type updated to `[Int: ScannerWindowRecord]`, (g) §4.1 sequential Int key rationale documented (ordering + duplicate-bundle-ID disambiguation), (h) OQ-4 updated with corrected API chain, (i) §2.1 G8 note arithmetic corrected 41.5 → 41.6.
- **0.3** (Round 2 response): 3 P1 + 4 P2 from Round 2. AU version via bundle plist, `openedByScanner` rekeyed, §7.2 AC-3.0 row, contentHash canonical, AC-2.10 decode recovery, E11c native-prompt, E32. Key changes: (a) AU version source changed from `AUPlugInGetVersionNumber` (requires instance) to **AU bundle Info.plist `CFBundleShortVersionString` via `AudioComponentCopyName` + bundle URL lookup** (no instantiation), (b) `openedByScanner` rekeyed from unstable AXUIElement-hash to `[Int: ScannerWindowRecord]` with sequential integer ID + stable bundle ID + window title pair (async-safe), (c) §7.2 adds AC-3.0 identity-mismatch ERROR row, (d) `contentHash` definition unified: xxhash of full recursive tree's `{name, kind, path}` serialized in AX-traversal order (single definition at §4.2), (e) AC-3.0 explicit lock-before-identifyPlugin ordering, explicit cache-miss branch, (f) AC-2.10 decode-failure recovery (corrupt JSON → empty cache, no crash), (g) AC-2.10 + AC-6.4 explicit test hooks, (h) E11c Automation permission — clarified prompt behavior (no silent pre-check, surface natively on first AXPress), (i) `nowMs` clarified as monotonic (mach_absolute_time / DispatchTime.uptimeNanoseconds), (j) E32 cache identity mismatch at set_plugin_preset, (k) G3 prose aligned with canonical naming, (l) AC-1.8 rephrased (flag at handler entry, not mutex on AX calls), (m) G8 CI measurement methodology note.
- **0.2** (Round 1 response): 2 P0 + ~20 P1 + ~15 P2 from Round 1. Key changes: §4 T0-conditional, canonical naming table, shared `axScanInProgress`, plugin identity via bundle ID, G2 rescoped, honest perf worst-case, PluginWindowRuntime seam, E4b/E26/E27/E28/E29, §7.2 ERROR logging, schema versioning.
- **0.1**: Initial draft.

---

## 1. Problem Statement

### 1.1 Background
LogicProMCP v2.1.0 ships `library.scan_all` and `track.set_instrument { path }` which achieve 100% coverage of **the Library panel** (Instrument / Patch browser). The Library panel exposes *patches* — multi-plugin Channel-Strip settings — but does **NOT** expose *plugin-internal presets*.

When the user loads an instrument plugin (e.g. ES2, Alchemy, Sculpture, Retro Synth, Sampler, Quick Sampler, Drum Machine Designer, Drum Kit Designer, EFM1, Ultrabeat, Vintage B3/Clav/EP, Studio Horns/Strings, Mellotron, Vocoder) and opens its plugin window, the window's **Setting dropdown** (Logic-managed header bar, top-center of every plugin window) lists every factory- and user-preset shipped with that plugin. A single Logic Pro 12 install ships thousands of such presets (Alchemy alone: ~3 000 patches across ~30 sub-categories). The MCP today cannot see or load any of them.

The user's intent *"모든 사운드 100% 파악"* requires enumerating every **currently-instantiated** instrument plugin's Setting-menu tree, so an LLM agent can ask for *"the Alchemy dark-pad called Silent Caverns"* or *"the ES2 preset Warm Fuzz"* and have the MCP navigate the menu hierarchy and load it.

### 1.2 Problem Definition
**The MCP cannot enumerate plugin-internal factory/user presets, nor can it load a preset by name, because no code walks the Plug-in Settings menu (`AXMenuButton → AXMenu → AXMenuItem` tree) exposed by Logic Pro's plugin-window header.**

### 1.3 Impact of Not Solving
- Library-panel patches ≠ plugin presets. A user asking *"load the Alchemy patch Silent Caverns"* is rejected because the MCP cannot see inside Alchemy.
- Agents cannot reason about timbre at the plugin-preset level.
- 90%+ of the shipped sound design in a Logic Pro 12 install is invisible to the MCP.
- The library-full-enumeration investment (v2.1.0) is unreachable at the plugin-internal level without this complementary surface.

---

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] **G1**: Enumerate **≥ 95% of leaves visible by manual menu traversal** of the Setting-menu tree (Factory Presets + User Presets + any other top-level groups) for any currently-open plugin window, via a single `plugin.scan_presets` MCP command. *Ground-truth reference*: `docs/test-live.md` §F2 manual counts per plugin (ES2 ≥ 300, Alchemy ≥ 1 500, Sculpture ≥ 250, Retro Synth ≥ 200). "Leaves" means `kind: leaf` (excludes separators/actions per §4.2).
- [ ] **G2**: Enumerate the Setting-menu preset tree for the **primary instrument in each track's instrument slot** across **every track currently carrying an instantiated instrument plugin** via `plugin.scan_all_instruments`. Returns `{ trackIndex → { pluginName, pluginIdentifier, presetRoot, cached?, error? } }`. Explicitly **excludes** (see §2.2): third-party plugins with no Logic-managed Setting menu (best-effort), DMD/DKD internal cells (deferred to F2.1), Alchemy Browse-tab content beyond what Setting menu exposes (deferred to F2.2).
- [ ] **G3**: `set_plugin_preset { trackIndex, path }` (MCP command per §4.1 canonical table) loads a leaf preset at `path` onto the specified track's currently-loaded plugin. Path uses `\/`-escape convention (same as library).
- [ ] **G4**: `plugin.resolve_preset_path { trackIndex, path }` — dry-run, cache-backed, zero AX clicks — for LLMs to validate before committing.
- [ ] **G5**: Achieve **≥ 90% line** + **≥ 85% branch** coverage on `PluginInspector.swift`, **100% branch** on new `AccessibilityChannel` plugin handlers.
- [ ] **G6**: Add **≥ 50 new tests** covering unit + integration + edge. Every new public function has ≥ 1 test whose name references it.
- [ ] **G7**: All existing tests continue to pass (baseline recorded at merge-base; must not delete or weaken any).
- [ ] **G8**: Performance at default `submenuOpenDelayMs: 300` on M-series Mac under normal load:
  - `scan_plugin_presets` p95: ES2-class (≤ 500 leaves, ≤ 10 submenus) ≤ **8 s**; Alchemy-class (≤ 3 000 leaves, ≤ 40 submenus) ≤ **30 s**.
  - `scan_all_instruments` p95: ≤ 20 instrument tracks, mixed plugins ≤ **180 s**.
  - *Worst-case acknowledgment*: at 800 ms submenu ceiling (see §4.5), Alchemy may reach 41.6 s and 20-track batch ~190 s. G8 targets are **default-delay p95**, explicitly not worst-case. Caller may tune down `submenuOpenDelayMs`; response records `measuredSubmenuOpenDelayMs`.

### 2.2 Non-Goals
- **NG1**: Effect / MIDI-FX plugin presets. Effect-rack enumeration is a separate AX surface; deferred to F2.3.
- **NG2**: Third-party AU/VST preset quality guarantees. Logic's header Setting menu *usually* exposes third-party AU presets, and the scanner will enumerate what it finds — but the PRD makes no coverage guarantee for non-Apple plugins.
- **NG3**: Plugin-internal browsers (Alchemy Browse tab, ES2 waveform browser). AUv3 custom views are generally AX-opaque. The Setting menu is the universal path.
- **NG4**: Editing / saving / tagging user presets. Read + select only.
- **NG5**: Preset audition (load-then-undo preview). Load is committed to the track.
- **NG6**: Plugins not currently instantiated on a track. Scanner only sees what Logic has loaded.
- **NG7**: Preset content analysis (which parameters the preset sets). Names + hierarchy only.
- **NG8**: Drum Machine Designer / Drum Kit Designer internal cell scan. The outer DMD/DKD shell's Setting menu is scanned; per-cell deferred to F2.1.

---

## 3. User Stories & Acceptance Criteria

### US-1: Single-Plugin Preset Scan
- [ ] **AC-1.1**: Given a plugin window is open and focused, when `tools/call logic_tracks scan_plugin_presets { trackIndex?: Int, submenuOpenDelayMs?: Int }` is called, then the response contains `root: PluginPresetNode` recursively with each node `{ name, path, kind: "folder"|"leaf"|"separator"|"action"|"truncated"|"probeTimeout"|"cycle", children: [...] }`. `separator` and `action` nodes are retained but marked.
- [ ] **AC-1.2**: Given the Setting menu has nested submenus, when the scanner traverses, then every leaf reachable by opening submenus is included at its correct `path`.
- [ ] **AC-1.3**: Given two back-to-back calls with no intervening user action on the same plugin window, the emitted JSON is **structurally identical on axes: `name`, `path`, `kind`, sibling order, and duplicate-disambiguator suffixes (`[i]`)**. Excluded from identity: `scanDurationMs`, `generatedAt`, `measuredSubmenuOpenDelayMs`. Byte-identity not required.
- [ ] **AC-1.4**: Given no plugin window is focused **and** no `trackIndex` is provided, when the call runs, then `{ isError: true, text: "No plugin window focused and no trackIndex supplied. Pass { trackIndex: N } or focus a plugin window." }`; MCP process does not crash.
- [ ] **AC-1.5**: Given `trackIndex: N` is provided, when the handler runs, then (a) track N is located, (b) the track's instantiated-instrument plugin is identified via AU bundle ID, (c) the plugin window is opened if not already open, (d) scanned, (e) the previous plugin-window *visibility* state is restored (re-closed if closed before call). Non-destructive.
- [ ] **AC-1.5b** (precedence): Given `trackIndex: N` is provided **and** a different plugin window is currently focused, when the handler runs, then **trackIndex wins** — focused-window state is ignored; handler always targets track N. The focused window is **not** closed or re-arranged; it remains where the user had it.
- [ ] **AC-1.6**: Given an M-series Mac at normal load, when the scanner runs with default `submenuOpenDelayMs: 300`, then p95 wall-time is ≤ 8 s for ES2-class, ≤ 30 s for Alchemy-class (§G8). Caller-tunable within `100…1000 ms`; response records `measuredSubmenuOpenDelayMs`.
- [ ] **AC-1.7**: Given scan completes, when the scanner persists to `Resources/plugin-inventory.json`, the file is valid UTF-8 JSON that round-trips through `JSONDecoder().decode(PluginPresetInventory.self, from:)` (NOT `PluginPresetCache` — the on-disk file is the inventory wrapper), carries `schemaVersion: 1`, contains no screen-coordinate data, and is gitignored.
- [ ] **AC-1.8**: Given the scanner uses `Task.sleep` between menu-opens, when invoked from `AccessibilityChannel` actor, other actor messages enter the mailbox normally (non-AX handlers such as `getTrackCount` run to completion). New calls to lock-guarded AX operations (see AC-1.9) are rejected **at handler entry** via the `axScanInProgress` flag check — the flag is a boolean gate, not a mutex protecting individual AX calls; intra-scan AX calls are already serialized by the actor.
- [ ] **AC-1.9** (cross-surface lock): Given any of `library.scan_all`, `plugin.scan_presets`, `plugin.scan_all_instruments`, or `plugin.set_preset` is already running, any subsequent call to any of those operations errors with `"<operation>: AX scan already in progress"` (shared `axScanInProgress: Bool` actor-state flag). `plugin.resolve_preset_path` is explicitly **exempt** (cache-only, no AX).

### US-2: Batch All-Instrument Scan
- [ ] **AC-2.1**: Given a project with N tracks where K are instrument tracks with instantiated instrument plugins, when `scan_all_instruments { onlyTracks?: [Int], skipAlreadyCached?: Bool, submenuOpenDelayMs?: Int }` is called, the response contains `tracks: [{ trackIndex, pluginName, pluginIdentifier, pluginVersion?, presetRoot, scanDurationMs, cached: Bool, error?: String }]` — one entry per instrument track. Audio / MIDI / Aux / Bus tracks are silently skipped.
- [ ] **AC-2.2**: Given `onlyTracks: [0, 3, 5]`, only those 3 tracks are scanned.
- [ ] **AC-2.3**: Given `skipAlreadyCached: true`, cache hit requires matching `pluginIdentifier` AND cached `pluginVersion` is **non-nil** AND equals the live version queried at scan time. If any condition fails (version nil in cache, version nil live, or mismatch), **rescan is forced**; cached `contentHash` is used only post-rescan to *confirm* the freshly-scanned tree matches the stored hash (in which case only metadata is refreshed). A validity check that compares cached `contentHash` against itself without rescan is forbidden — that check would be vacuously true.
- [ ] **AC-2.4**: Given one track's scan errors, the batch records `error: <msg>` for that track and continues; the track's plugin window (if opened by scanner) is closed before moving to the next track. Batch does **NOT** error.
- [ ] **AC-2.5**: Given a track has an instrument plugin not previously opened, the scanner opens the window, scans, then closes it. After the batch, the mixer UI state is unchanged.
- [ ] **AC-2.6** — covered by AC-1.9 (shared lock).
- [ ] **AC-2.7**: Given the batch completes, the aggregate is written to `Resources/plugin-inventory.json` keyed by `pluginIdentifier` → `PluginPresetCache`, wrapped in `PluginPresetInventory { schemaVersion, generatedAt, plugins: [identifier: cache] }`.
- [ ] **AC-2.8** (reconciliation on per-track error): Given a per-track scan errors after the scanner opened that plugin window, the reconciliation code **MUST** close that window before proceeding to the next track. A batch-level **`openedByScanner: [Int: ScannerWindowRecord]`** ledger maps a sequential integer ID (assigned at open time, preserves open-order for deterministic reconciliation traversal + disambiguates same-bundle-ID multi-window case) to `ScannerWindowRecord { cgWindowID, bundleID, windowTitle, element }`. **Lookup for close uses `cgWindowID` as primary key** — `CGWindowID` is a stable process-wide integer captured at open time via `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` filtered by `kCGWindowOwnerPID == Logic.pid` and `kCGWindowLayer == 0`, then matched against the AXUIElement's `AXWindowID` attribute. If `cgWindowID` is 0/unavailable (rare AX inconsistency), fall back to `(bundleID, windowTitle)` pair + `openedByScanner` ledger's Int key as secondary disambiguator. Never relies on `AXUIElement` pointer hash (which may be invalidated by AX server GC across async Task suspension).
- [ ] **AC-2.9** (reconciliation failure): Given `closePluginWindow` fails during reconciliation, the response includes `reconciliationWarnings: [{ trackIndex, pluginName, error }]`; the batch **does not** error.
- [ ] **AC-2.10** (cache persistence across process restart): On `AccessibilityChannel` init, if `Resources/plugin-inventory.json` exists **and** its `schemaVersion` matches the current implementation, it is loaded into in-memory `pluginPresetCache`. Version mismatch → cache is **not** loaded; a clear log line records the skip. **Decode failure (corrupt JSON, truncated file, malformed UTF-8, duplicate keys) → log ERROR, start with empty cache, do not crash.** `skipAlreadyCached` then checks the in-memory map (disk-backed on startup, lazy-written at scan completion). **Test requirement**: §8.2 includes an integration test for channel init against (a) valid cache file, (b) version-mismatch file, (c) corrupt JSON file, asserting in-memory cache state + no crash.

### US-3: Path-Addressed Preset Load
- [ ] **AC-3.0** (plugin identity gate): Lock is acquired (`axScanInProgress = true`, see AC-1.9) **before any AX read**, including `identifyPlugin`. Sequence:
  (a) acquire lock,
  (b) locate / open target window for track N,
  (c) call `identifyPlugin(in: window)` → live `(name, bundleID, version)`,
  (d) look up `pluginPresetCache[bundleID]` — **if no cache entry exists**, return `{ isError: true, text: "No cached preset tree for plugin <bundleID> on track N; call scan_plugin_presets first" }` without any menu click,
  (e) verify the requested `path` exists as a leaf within `pluginPresetCache[bundleID].root` — if not, return `{ isError: true, text: "Preset not found at path: <path> in cached tree for plugin <bundleID>" }`. This *implicitly* detects the "user swapped the plugin since the path was emitted" case because the swap would make the path unresolvable in the new plugin's cache (or there would be no cache at all, handled by step d).
  (f) otherwise proceed to navigate.
  **The gate uses only the live `bundleID` as identity comparator — not path inference.** There is no "expected vs live" bundleID comparison in AC-3.0: a plugin swap is detected implicitly because swapping to a different plugin means `pluginPresetCache[newLiveBundleID]` has no entry (step d) or the prior path does not resolve in the new plugin's tree (step e). Both firing paths have distinct §7.2 ERROR log entries with `liveBundleID` as the sole identity field.
- [ ] **AC-3.1**: Given track `N` has plugin `P` with cached path `"Factory Presets/Pads/Silent Caverns"` resolving to a leaf, when `set_plugin_preset { trackIndex: N, path }` runs, then (a) the plugin window is opened if closed, (b) Setting dropdown is clicked, (c) each submenu is opened in order, (d) the leaf is clicked. Response: `{ trackIndex, pluginName, pluginIdentifier, preset, path }`.
- [ ] **AC-3.2**: Given path does not resolve to a leaf, when call runs, then `{ isError: true, text: "Preset not found at path: <path>" }`.
- [ ] **AC-3.3** (folder/separator/action): Given path resolves to a `folder`, `separator`, or `action` node, when call runs, then `{ isError: true, text: "Path resolves to a menu <kind>, not a loadable preset: <path>" }`. Rationale: `action` nodes mutate user state (e.g. *"Save As Default…"*) — must never be auto-clicked.
- [ ] **AC-3.4**: Path escape — `/` in name → `\/`; `\` → `\\`. Parse order: `\\` → `\`, then `\/` → `/`.
- [ ] **AC-3.5**: Given `trackIndex` is out of range, when call runs, then `{ isError: true, text: "Track at index N not found" }` before any window mutation.
- [ ] **AC-3.6**: Given track exists but has no instrument plugin, `{ isError: true, text: "Track N has no instrument plugin loaded" }`.
- [ ] **AC-3.7** (window restore): Given plugin window was closed before the call, when the call completes (success **or** error), the window visibility is restored to pre-call state. Exception: if a cleanup AX call itself errors, log WARN but do not re-throw; response still returns the original outcome.

### US-4: Dry-Run Path Resolution
- [ ] **AC-4.1**: Given cache entry for the track's plugin exists, when `resolve_preset_path { trackIndex, path }` runs, then **zero AX clicks** occur; returns `{ exists: Bool, kind: "folder"|"leaf"|"action"|"separator"|"cycle"|"truncated"|"probeTimeout"|null, matchedPath: String?, children: [String]? }`. `children` populated for `kind: folder`; empty array for leaf/action/separator (explicit, not omitted, to avoid LLM ambiguity).
- [ ] **AC-4.2**: Given no cache exists for the plugin, returns `{ exists: false, reason: "no_cache", hint: "Call scan_plugin_presets on this track first." }` without opening any window.
- [ ] **AC-4.3**: Trailing slash `"Bass/"` is stripped; lookup proceeds as-if without trailing slash.
- [ ] **AC-4.4**: Empty string or `"/"` returns the root node's children + `matchedPath: ""`.

### US-5: Plugin Window Lifecycle Correctness
- [ ] **AC-5.1**: Plugin window closed before `scan_plugin_presets { trackIndex: N }` → closed after (success path).
- [ ] **AC-5.2**: Plugin window open before the call → remains open.
- [ ] **AC-5.3** (identity + locale): Given the scanner opened a plugin window for track N, when it identifies the window's plugin, then identity comparison uses `AXIdentifier` / AU bundle ID **first** (locale-invariant), then `AXDescription` in English locale fallback, then AXTitle last. Mismatch → abort with `"Plugin window mismatch on track N: expected <bundle A>, got <bundle B>"`. **On mismatch-abort, the handler closes the just-opened window IF the scanner opened it (pre-state was closed), then returns the error** (no lingering window).
- [ ] **AC-5.4**: Plugin window open attempt must succeed within **2000 ms**; otherwise `{ isError: true, text: "Plugin window did not open within 2000 ms on track N" }`.
- [ ] **AC-5.5**: Given `scan_all_instruments` processes M tracks, at batch end no plugin window is left open that the scanner opened. Pre/post delta on windows-opened-by-scanner = 0. Windows that were open before the batch started remain open.
- [ ] **AC-5.6**: Given `closePluginWindow` fails in the reconciliation phase of a batch, the response's `reconciliationWarnings` enumerates affected tracks. Batch does not error (covered by AC-2.9 — listed again here for lifecycle traceability).

### US-6: Test Coverage Mandate
- [ ] **AC-6.1**: `swift test` → `PluginInspector.swift` ≥ 90% line, ≥ 85% branch; new `AccessibilityChannel` plugin-handler branches 100%.
- [ ] **AC-6.2**: ≥ 50 new tests; every new public function has ≥ 1 test naming it.
- [ ] **AC-6.3**: Total project tests ≥ `(baseline_at_merge_base + 50)`. Baseline captured from `main` at merge-base; no existing test deleted or weakened.
- [ ] **AC-6.4** (rollout correctness): At merge, `.gitignore` contains the pattern `Resources/*-inventory.json` (covers both `library-inventory.json` and `plugin-inventory.json`); `TrackDispatcher` tool description lists `scan_plugin_presets`, `scan_all_instruments`, `set_plugin_preset`, `resolve_preset_path` with param schemas.

---

## 4. Technical Design

### 4.1 Architecture Overview

**Canonical naming table** (MCP command ↔ router op ↔ handler method — authoritative; all downstream sections use these):

| MCP Tool Command (user-facing) | Router Operation (internal) | `AccessibilityChannel` handler |
|--------------------------------|----------------------------|--------------------------------|
| `scan_plugin_presets` | `plugin.scan_presets` | `scanPluginPresets(_:)` |
| `scan_all_instruments` | `plugin.scan_all_instruments` | `scanAllInstruments(_:)` |
| `set_plugin_preset` | `plugin.set_preset` | `setPluginPreset(_:)` |
| `resolve_preset_path` | `plugin.resolve_preset_path` | `resolvePluginPresetPath(_:)` |

Existing placeholders in `ChannelRouter.swift:163-166` (`plugin.list`, `plugin.insert`, `plugin.bypass`, `plugin.remove`) are **untouched by F2**.

```
MCP Dispatcher (TrackDispatcher.swift)
   │
   ├── "scan_plugin_presets"       ──▶ router.route("plugin.scan_presets", …)
   ├── "scan_all_instruments"      ──▶ router.route("plugin.scan_all_instruments", …)
   ├── "set_plugin_preset"         ──▶ router.route("plugin.set_preset", …)
   └── "resolve_preset_path"       ──▶ router.route("plugin.resolve_preset_path", …)
          │
          ▼
ChannelRouter — routes [.accessibility]
          │
          ▼
AccessibilityChannel (EXISTING actor; NEW handlers, EXPANDED state)
   ├── scanPluginPresets / scanAllInstruments / setPluginPreset / resolvePluginPresetPath
   └── Actor state additions
          ├── axScanInProgress: Bool       // SHARED with library — renamed from scanInProgress
          ├── pluginPresetCache: [String: PluginPresetCache]     // key = pluginIdentifier
          ├── lastPluginWindowState: [Int: WindowState]          // key = trackIndex (for restore)
          ├── openedByScanner: [Int: ScannerWindowRecord]        // batch-level ledger, keyed by sequential int ID
          └── nextScannerWindowID: Int                           // monotonic counter for ledger keys
          │
          ▼
PluginInspector (NEW file ~600-800 lines; mirrors LibraryAccessor pattern)
   ├── enumerateMenuTree(probe:maxDepth:)          → PluginPresetNode
   ├── resolveMenuPath(_: String, in: root)        → [MenuHop]
   ├── selectMenuPath(_: [MenuHop])                → navigates + clicks
   ├── findPluginWindow(for trackIndex:) async     → AXUIElement?
   ├── findSettingDropdown(in window:)             → AXUIElement?
   ├── identifyPlugin(in window:)                  → (name: String, bundleID: String, version: String?)?
   ├── openPluginWindow(for trackIndex:) async     → AXUIElement
   ├── closePluginWindow(_:) async                 → Bool
   └── productionMenuItemClick(at:)                → Bool
          │ (CGEvent fallback path, IF T0 determines AXPress unreliable,
          │  is NOT reinvented — it CALLS the existing canonical impl at
          │  LibraryAccessor.productionMouseClick(at:). T1 ticket wires
          │  this reuse via a Runtime closure. See §4.4 + §10.2.)
          ▼
AXLogicProElements / AXHelpers / LibraryAccessor.productionMouseClick (EXISTING — unchanged)
```

**Key differences from library design**:
1. **Menu tree, not browser tree.** AX surface is `AXMenu` / `AXMenuItem`. The primary interaction mechanism (AXPress vs CGEvent) is **T0-gated** — see §4.4 and §12 OQ-1.
2. **Plugin-window lifecycle.** Library is a fixed panel; plugin windows open/close. Scanner manages visibility with a batch-level ledger.
3. **Per-plugin cache, shared across tracks.** ES2 on track 1 and ES2 on track 5 share one cache entry keyed by AU bundle ID.

**Reused patterns** (explicitly NOT redesigned):
- `PluginPresetProbe` mirrors `TreeProbe` (closure injection for test determinism).
- `axScanInProgress: Bool` shared mutex between library + plugin scans (rename from current `scanInProgress`).
- Path-escape `\/` convention identical to library.
- `productionMenuItemClick` — delegates to `LibraryAccessor.productionMouseClick` via Runtime when CGEvent path is used (no re-implementation).

### 4.2 Data Model

```swift
public enum PluginPresetNodeKind: String, Codable, Sendable, Equatable {
    case folder, leaf, separator, action
    case truncated, probeTimeout, cycle   // all three surface-error states explicit
}

public struct PluginPresetNode: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: PluginPresetNodeKind
    public let children: [PluginPresetNode]
    // No screen coordinates; resolved live at click time.
}

public struct PluginPresetCache: Codable, Sendable, Equatable {
    public let schemaVersion: Int          // currently 1
    public let pluginName: String          // e.g. "ES2"
    public let pluginIdentifier: String    // stable key — AU bundle ID, e.g. "com.apple.audio.units.ES2"
    public let pluginVersion: String?      // from AU bundle Info.plist `CFBundleShortVersionString` (see §4.4); nil only if bundle lookup fails
    public let contentHash: String         // **CANONICAL DEFINITION**: xxhash64 of UTF-8 bytes of the full recursive tree serialized as `{name}\0{kind}\0{path}\n` (per node, depth-first in AX-traversal order). One definition used everywhere.
    public let generatedAt: String
    public let scanDurationMs: Int
    public let measuredSubmenuOpenDelayMs: Int
    public let truncatedBranches: Int
    public let probeTimeouts: Int
    public let cycleCount: Int
    public let nodeCount: Int
    public let leafCount: Int
    public let folderCount: Int
    public let root: PluginPresetNode
}

public struct PluginPresetInventory: Codable, Sendable, Equatable {
    public let schemaVersion: Int          // currently 1
    public let generatedAt: String
    public let plugins: [String: PluginPresetCache]   // key = pluginIdentifier
}

public struct MenuHop: Sendable, Equatable {
    public let indexInParent: Int
    public let name: String
}

public struct PluginMenuItemInfo: Sendable, Equatable {
    public let name: String
    public let kind: PluginPresetNodeKind
    public let hasSubmenu: Bool
}

public struct PluginPresetProbe: Sendable {
    public let menuItemsAt: @Sendable ([String]) async -> [PluginMenuItemInfo]?
    public let pressMenuItem: @Sendable ([String]) async -> Bool   // T0-gated: AXPress or CGEvent-fallback routing
    public let focusOK: @Sendable () async -> Bool
    public let mutationSinceLastCheck: @Sendable () async -> Bool
    public let sleep: @Sendable (Int) async -> Void
    public let visitedHash: @Sendable ([String]) -> Int
}

public struct PluginWindowRuntime: Sendable {
    public let findWindow: @Sendable (Int) async -> AXUIElementSendable?
    public let openWindow: @Sendable (Int) async throws -> AXUIElementSendable
    public let closeWindow: @Sendable (AXUIElementSendable) async -> Bool
    public let listOpenWindows: @Sendable () async -> [AXUIElementSendable]
    public let identifyPlugin: @Sendable (AXUIElementSendable) async -> (name: String, bundleID: String, version: String?)?
    // Monotonic millisecond clock — REQUIRED to use a monotonic source (e.g. DispatchTime.now().uptimeNanoseconds / 1_000_000
    // or mach_absolute_time-based), NOT wall-clock time, to survive NTP adjustments during long scans.
    public let nowMs: @Sendable () -> Int
}

public struct ScannerWindowRecord: Sendable, Equatable {
    public let cgWindowID: CGWindowID         // PRIMARY key — stable integer from CGWindowListCopyWindowInfo at open time; survives AX GC
    public let bundleID: String               // AU bundle identifier — used for disambiguation in logs + fallback re-resolution
    public let windowTitle: String            // AXTitle at open time — fallback secondary disambiguator only
    public let element: AXUIElementSendable   // live pointer at open time; close-time re-resolution uses cgWindowID to find the live element in the current AX tree
}
// AXUIElementSendable — NEW Sendable wrapper introduced by this PRD (no F1 predecessor).
// AXUIElement is a CoreFoundation type without built-in Sendable conformance; @unchecked
// is safe because the element is only dereferenced on the AccessibilityChannel actor.
public final class AXUIElementSendable: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}
```

`AXUIElementSendable` — see concrete definition at end of this §4.2 block; NEW type introduced by this PRD, no F1 predecessor.

### 4.3 API Design

| MCP Command | Params | Description |
|-------------|--------|-------------|
| `scan_plugin_presets` | `{ trackIndex?: Int, submenuOpenDelayMs?: Int }` | Single-plugin scan. |
| `scan_all_instruments` | `{ onlyTracks?: [Int], skipAlreadyCached?: Bool, submenuOpenDelayMs?: Int }` | Batch every instrument track. |
| `set_plugin_preset` | `{ trackIndex: Int, path: String }` | Navigate + click leaf. |
| `resolve_preset_path` | `{ trackIndex: Int, path: String }` | Cache-only dry-run. |

Rejection rule: `set_plugin_preset` rejects any param other than `trackIndex` + `path`. No legacy `{category, preset}` shape exists for plugins (would be ambiguous — plugin menus are arbitrary-depth).

### 4.4 Key Technical Decisions

| Decision | Options | Chosen | Rationale |
|----------|---------|--------|-----------|
| Tree representation | (a) flat map, (b) recursive `PluginPresetNode` | (b) | Mirrors library; paths readable; LLMs parse trees well. |
| **Menu interaction — T0 RESOLVED v0.6: MIXED** | (a) AXPress only, (b) CGEvent only, (c) MIXED | **(c) MIXED**: CGEvent click via `LibraryAccessor.productionMouseClick` for Setting popup open (popup AXPress returns `.cannotComplete` -25204 despite UI effect — unreliable across macOS versions); AXPress on AXMenuItem for submenu navigation (100% reliable, 0 response code, lazy-populate works); AXCancel for menu dismiss. | Empirical T0 probe `Scripts/setting-popup-probe.swift`: 35 top-level items, 11 hierarchical submenus populate via AXPress; popup AXPress unreliable. CGEvent for popup open is the same proven path as F1 library. |
| CGEvent fallback implementation | (a) Re-implement, (b) Delegate to existing `LibraryAccessor.productionMouseClick` via Runtime closure | (b) | Existing impl already handles center-point calc, focus-guard, retry, verify. Re-implementing would invite the same bugs library fixed over 3 review rounds. |
| Plugin window identity (AC-5.3) — **T0 v0.6 corrected** | (a) AXIdentifier (empirically nil — unavailable), (b) AXDescription (empirically nil), (c) AXTitle (empirically = patch name, NOT plugin name — e.g. "Acoustic Guitar" patch when ES2 is loaded), (d) **AU registry via track-index → instrument slot → `AVAudioUnitComponent` bundle ID**, (e) AXStaticText scan within window for cross-validation | **(d) primary + (e) secondary** | T0 spike empirically confirmed AX identity attributes nil on Logic 12.0.1 plugin windows. Only reliable identity is via AU registry queried by track instrument-slot. The AXStaticText `"ES2"` inside the window provides cross-validation (PluginInspector helper). |
| Scan serialization | (a) per-plugin lock, (b) shared `axScanInProgress` mutex covering library + plugin scans + `set_plugin_preset` | (b) | Library + plugin scans both drive the same Logic UI thread; running concurrently would fight for AX tree attention. `set_plugin_preset` mutates plugin state and must also serialize. `resolve_preset_path` is cache-only → exempt. |
| Cache key | (a) display name, (b) AU bundle ID | (b) | Display name localizes; bundle ID stable. |
| Cache version source | (a) `AUPlugInGetVersionNumber` (requires `AudioComponentInstance` — needs `AudioComponentInstanceNew`, disruptive), (b) **`AudioComponentGetVersion(audioComponent, &version)`** — free function returning `UInt32` directly **without instantiating**, (c) `AVAudioUnitComponent.versionString` + `.componentURL` via `AVAudioUnitComponentManager.shared().components(matching:)`, (d) content-hash fallback | **(b) primary; (c) secondary (for human-readable string + bundle URL if needed); (d) fallback** | Option (a) requires in-process instantiation — heavy, disruptive to Logic's instance. Option (b) is the correct zero-instantiation API — returns the AU's version as a packed `UInt32` (format: `0xMMMMmmbb`, major/minor/bugfix). Option (c) wraps (b) in AVFoundation's component manager and additionally exposes `componentURL` (Info.plist path) for `CFBundleShortVersionString` human string if ever needed. **Not `AudioComponentCopyName`** — that returns only a name string, not a URL. When all lookups fail (third-party AU not in Logic's search path, registry unreachable), fall back to `contentHash` (see §4.2 canonical definition). |
| Cache validity | (a) identifier only, (b) identifier + non-nil version match, (c) identifier + non-nil version match; `contentHash` used **only post-rescan** to confirm freshly-scanned tree matches stored hash (never as skip-guard — see AC-2.3 + E22) | (c) | Handles pluginVersion-nil case without silent staleness: nil version always forces rescan. **Critical**: checking cached `contentHash` against itself without rescan is vacuously true and forbidden. **Note on contentHash determinism**: computed on AX-traversal order (not sorted); if AX returns items non-deterministically for a plugin with dynamically-built menus, post-rescan confirmation may flag false-positive drift (→ cache metadata refresh still happens). Accepted risk. |
| Window restore | (a) always leave as-found, (b) leave open if caller asked | (a) | Non-surprise; batch must not pollute UI. |
| Depth cap | 10 (hard) + visited-hash set | — | Cocoa NSMenu nests rarely > 4 levels; 10 is generous; visited-hash protects cycles regardless. |
| Submenu-open delay | Hybrid: poll every 50 ms up to 800 ms ceiling; floor 300 ms | — | Balances speed with reliability. |
| Plugin window close | (a) AXPress close button, (b) AXCancel, (c) CGEvent ⌘W | (a) primary, (c) fallback | Close button is standard AXCloseButton; responds to AXPress. |
| Test mocking | Closure-based `PluginPresetProbe` + `PluginWindowRuntime` | — | Consistency with library pattern; enables unit tests without live Logic. |
| **Menu mutation signal** | (a) hash top-level menu names at scan start + periodic recheck, (b) subscribe to AX notifications, (c) column-specific invariant | (a) | Simpler than AX notifications; Logic doesn't emit consistent AX notifications for menu changes. Periodic recheck cadence: before every AXPress. Guard window = AXPress dispatch → `measuredSubmenuOpenDelayMs` elapsed → children-read complete; **floor 300 ms**. |
| **Menu scan AX ordering determinism** | Preserve AX order, do not sort | — | Matches what user sees; sort would lie. AC-1.3 relies on this. |
| **Cache persistence** | In-memory only vs disk-backed lazy-write | Disk-backed: load on `AccessibilityChannel` init (if schemaVersion matches), lazy-write at scan end | Mirrors expected LLM behavior (cache once, use many). |
| **Regression on F1** | F1 types (`LibraryNode`, `LibraryRoot`, `TreeProbe`) are NOT modified | — | Prevents F2 creep into F1 surface. |

### 4.5 Performance Model (honest worst-case)

```
T_scan(single plugin) = folderCount × submenuSettleMs
                     + menuItemReadMs × nodeCount
                     + menuCloseMs
                     + overhead

T_batch(K tracks)     = Σ_k [ (window opened by scanner ? openCost + identifyCost + closeCost : 0)
                            + T_scan(plugin_k) ]
                     + reconciliationCost

Where (empirical M-series, default config):
  submenuSettleMs     : 300 ms (floor, typical) … 800 ms (ceiling, worst)
  menuItemReadMs      : ≤ 3 ms
  menuCloseMs         : ~100 ms (Escape key via AXPress)
  openCost            : ~500 ms (slot double-click → window appears)
  identifyCost        : ~50 ms (AX bundle ID read)
  closeCost           : ~200 ms (AXPress close button)
  reconciliationCost  : up to closeCost × windowsOpenedByScanner

Examples:

  ES2         (10 folders × 300 + 350 leaves × 3 + 100 + 200)   ≈  4.4 s
  Alchemy     (40 folders × 300 + 3000 leaves × 3 + 100 + 500)  ≈  21.6 s (typical)
  Alchemy worst-case (40 folders × 800 + same)                   ≈  41.6 s  ⚠ exceeds G8 30s
  Batch 20 tracks (avg 5s typical + 750ms per-track overhead)    ≈ 115 s   (≤ G8 180 s)
  Batch 20 tracks worst-case                                      ≈ 190 s   ⚠ marginally exceeds
```

**G8 is the default-delay p95 contract** — not worst-case guarantee. Worst-case (all submenus at 800 ms ceiling, all plugin windows slow-to-open) is explicitly acknowledged above G8 spec (see §2.1 G8 note). Callers hitting the ceiling repeatedly should lower `submenuOpenDelayMs` or rescan offline.

---

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | No plugin window focused and no `trackIndex` | `isError: true`, text *"No plugin window focused…"* (AC-1.4) | P1 |
| E2 | Plugin window open but no Setting dropdown (third-party AU without Logic-managed header) | `isError: true`, text *"Plugin window has no Setting menu (third-party AU?). Best-effort NG2 scope."* | P2 |
| E3 | Setting menu opens but is empty (no presets) | Return tree with `leafCount: 0, root.children: []`; not an error | P3 |
| E4 | Two sibling menu items with identical name | Both retained, `[0]`/`[1]` suffix in path | P2 |
| E4b | Logic Pro UI in non-English locale (Korean / Japanese / German) | `findSettingDropdown` locates by role `AXMenuButton` + *header-bar region of plugin window* (not localized description). Identity compared by bundle ID (AC-5.3), never description. If dropdown not found: `"Setting dropdown not found in plugin window header"` error. | P1 |
| E5 | Preset name contains `/` | Path escaped as `\/`; decoder un-escapes | P2 |
| E6 | Menu tree mutates mid-scan (external cause — user keystroke rebuilds menu) | Abort with `"Plugin menu changed during scan"`; partial tree NOT cached; `axScanInProgress` cleared via `defer` | P1 |
| E6b | Menu mutates because scanner opened a submenu (expected) | Guard window (AXPress → settle → children read, floor 300 ms) suppresses E6; scanner's own op does not trigger abort | P2 |
| E7 | Unicode / RTL preset names | Preserved byte-for-byte in JSON | P2 |
| E8 | Submenu AXPress fires but children never populate within 800 ms | Emit `kind: probeTimeout`; scan continues | P2 |
| E9 | Depth > 10 | Truncate branch with `kind: truncated`; WARN log | P2 |
| E9b | AX re-emits same menu element at deeper path (cycle) | Visited-hash set terminates with `kind: cycle`; `cycleCount++` in `PluginPresetCache` | P2 |
| E10 | Logic Pro not running | Existing appRoot check returns `"Logic Pro is not running"` | P1 |
| E11 | MCP lacks Accessibility permission | `AXIsProcessTrusted()` check → `"Accessibility permission required"` before any plugin-scan | P0 |
| E11b | MCP lacks Post-Event capability — **v0.6 unconditional** (T0 verdict = MIXED requires CGEvent for Setting popup open) | `CGPreflightPostEventAccess()` check before any plugin-scan/set. Missing → fail with `"Event-post permission required for plugin Setting popup open; grant in System Settings → Privacy & Security → Accessibility"`. | **P0 unconditional** |
| E11c | macOS Automation (AppleScript consent) prompt fires natively on first AXPress of a Cocoa NSMenu on Logic Pro (macOS 13+) | Scanner does NOT pre-check via `AEDeterminePermissionToAutomateTarget` (would duplicate the native prompt). First AXPress triggers the OS prompt; user grant → proceed, user deny → `AXUIElementPerformAction` returns `.apiDisabled` which handler wraps as `"Automation permission required for plugin menu navigation; grant in System Settings → Privacy & Security → Automation"`. | P1 |
| E12 | `set_plugin_preset` with params other than `{trackIndex, path}` | Reject with `"Invalid params; set_plugin_preset accepts only { trackIndex, path }"` | P3 |
| E13 | `trackIndex` valid but track is Audio/MIDI/Aux/Bus (no instrument plugin) | `isError: true`, *"Track N has no instrument plugin loaded"* | P2 |
| E14 | Plugin on track is effect/MIDI-FX (not instrument) | Skip silently in batch; error in single: *"Plugin at track N is not an instrument"* | P2 |
| E15 | Concurrent AX scan (library or plugin, any direction) | Shared `axScanInProgress` blocks; second call errors *"<op>: AX scan already in progress"* (AC-1.9) | P1 |
| E16 | AX call returns axError (e.g. -25205) | Wrap in `.error(description)`; no panic; `defer` clears scan flag | P1 |
| E17 | `AXValueGetValue` force-unwrap crash risk | All `as!` on AXValue → `as? AXValue` + guard; nil → `.error("AX position data unavailable")` | P1 |
| E18 | `set_plugin_preset` errors mid-navigation (e.g. user closes window) | Return structured error; attempt to close any window the handler opened; if close errors, log WARN but do not re-throw | P2 |
| E19 | Plugin window did not open within 2000 ms | `isError: true`, *"Plugin window did not open within 2000 ms on track N"* (AC-5.4) | P1 |
| E20 | Window AXIdentifier (bundle ID) mismatch post-open | Abort with *"Plugin window mismatch: expected <A>, got <B>"*; scanner-opened window closed before return (AC-5.3) | P1 |
| E21 | Per-track scan fails in batch | Record `error` in track entry; close scanner-opened window; continue (AC-2.4 + AC-2.8) | P2 |
| E22 | Cache entry with `pluginVersion` nil (in cache, live, or both) | **Always force rescan.** `contentHash` is **never** used as a skip-guard — checking cached `contentHash` against itself without a fresh scan is vacuously true (forbidden by AC-2.3). `contentHash` is used only *post-rescan* to confirm the freshly-scanned tree equals the stored hash (metadata refresh only). Any `(version nil ↔ non-nil)` transition also rescans. | P3 |
| E23 | Cache file write fails (permission / disk full) | Scan result still returned; WARN log; `cachePath` omitted from response | P2 |
| E24 | `path` contains empty segment (`"A//C"`) | Error: *"Invalid path: empty segment"* | P3 |
| E25 | User closes Logic Pro mid-scan | Abort with *"Logic Pro closed during scan"*; `defer` clears flag | P1 |
| E26 | Multiple plugin windows open for same track (main + floating Effects view) | `findPluginWindow(for:)` returns the window whose bundle ID matches the track's instrument slot AND whose header has a Setting dropdown; if multiple match, first; INFO log | P2 |
| E27 | Plugin window closes mid-scan (user ⌘W) | AXPress hits dead element → E16 wraps as `"Plugin window closed during scan"`; flag cleared via defer | P2 |
| E28 | Plugin window enters fullscreen / zooms / minimizes mid-scan | AX tree state may desync with screen coords; abort with *"Plugin window state changed; scan aborted"*; close scanner-opened windows | P2 |
| E29 | Track has DMD / DKD loaded (outer shell only scannable per §NG8) | Entry emitted with `pluginName: "Drum Machine Designer"`, `limitationNote: "Outer shell scanned; per-cell presets deferred to F2.1"` field on the cache | P3 |
| E30 | Track structure mutates mid-batch (user adds/deletes track) | MCP does not detect; client must serialize. Documented in `AGENTS.md`. | P3 |
| E31 | `pluginIdentifier` lookup via AU registry fails (plugin not in registry, third-party without standard bundle) | Use **`AXIdentifier`** (locale-invariant AX equivalent) as the fallback cache key when available — NOT `AXDescription` (localizes) and NOT `contentHash` (would mutate the key every scan, destroying cache continuity). If neither `pluginIdentifier` nor `AXIdentifier` is available, return `{ isError: true, text: "Plugin not in AU registry and has no stable AX identifier; cannot cache" }`. Log WARN. | P3 |
| E32 | `set_plugin_preset` called when live plugin's `bundleID` does not have a cached preset tree (either no prior scan, or user reloaded a different plugin between scan and set) | AC-3.0 step (d) fires: `pluginPresetCache[liveBundleID]` lookup returns nil → return `{ isError: true, text: "No cached preset tree for plugin <liveBundleID> on track N; call scan_plugin_presets first" }`. No menu click occurs. ERROR log per §7.2 row "cache-miss on live bundle ID" uses `liveBundleID` + `reason:"no_cache_for_live_plugin"` (no prior-key comparison — cache miss is the firing condition). | P2 |

---

## 6. Security & Permissions

### 6.1 Authentication
N/A — local stdio MCP.

### 6.2 Authorization

| Role | scan_plugin_presets | scan_all_instruments | set_plugin_preset | resolve_preset_path |
|------|--------------------|----------------------|-------------------|---------------------|
| MCP caller (local user) | ✓ | ✓ | ✓ | ✓ |

### 6.3 macOS TCC Permissions

| Permission | Purpose | Detection | Missing → behaviour |
|-----------|---------|-----------|---------------------|
| Accessibility | `AXUIElementCopyAttributeValue`, `AXUIElementPerformAction` | `AXIsProcessTrusted()` | Fail fast; no scan. |
| Post-Event | Only if T0 picks CGEvent fallback | `CGPreflightPostEventAccess()` | If T0 = AXPress: not checked. If T0 = CGEvent: required; missing → *"Event-post permission required"*. |
| Automation (System Events) | Some macOS 13+ installs prompt on first AXPress of a Cocoa NSMenu on a target app | No silent pre-check. The OS natively surfaces its consent prompt on the **first AXPress attempt** that requires Automation (no separate probe). Explicit `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: true)` is **not** used — it would duplicate the native prompt. | First AXPress surfaces OS prompt. If user denies, `AXUIElementPerformAction` returns `.apiDisabled` (-25212) or similar; handler wraps as *"Automation permission required for plugin menu navigation; grant in System Settings → Privacy & Security → Automation"*. |

Surfaced via existing `system.permissions` MCP tool.

### 6.4 Data Protection
- Inventory JSON contains preset names + plugin identifiers only. No audio, no user content, no PII.
- Gitignored pattern: `Resources/*-inventory.json` (covers library + plugin).
- No network egress. No telemetry.

---

## 7. Performance & Monitoring

### 7.1 Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| scan_plugin_presets (ES2-class, default 300 ms) | ≤ 8 s p95 | `scanDurationMs` |
| scan_plugin_presets (Alchemy-class, default 300 ms) | ≤ 30 s p95 | `scanDurationMs` |
| scan_all_instruments (≤ 20 tracks, default 300 ms) | ≤ 180 s p95 | sum per-plugin + overhead |
| set_plugin_preset (cache hit + open → click) | ≤ 3 s p95 | server-side timer |
| Submenu-open settle | hybrid: 50 ms poll × 800 ms ceiling, **250 ms floor** (T0 empirical floor on ES2; PRD ≤0.5 said 300 ms) | `measuredSubmenuOpenDelayMs` |
| Memory peak during scan | < 60 MB incremental | `os_proc_available_memory()` |
| Max menu-tree depth | 10 | hard constant |

**G8 CI measurement methodology**: G8 p95 targets are asserted only when `measuredSubmenuOpenDelayMs` averaged over the scan is **≤ 400 ms**. Runs with average `measuredSubmenuOpenDelayMs > 400 ms` (indicating AX system-wide slowness, memory pressure, or Logic Pro under heavy load) are marked "degraded" in the test report — the scan still completes and returns data, but the timing assertion is skipped. This prevents CI flakiness while preserving the contract at default conditions.

### 7.2 Logging

| Event | Level | Keys |
|-------|-------|------|
| `scan_plugin_presets` success | INFO | `{ subsystem:"plugin", pluginName, nodeCount, leafCount, folderCount, durationMs, probeTimeouts, cycleCount }` |
| `set_plugin_preset` navigation | DEBUG | resolved menu-hop sequence |
| `scan_plugin_presets` abort (E6, E25, E27, E28) | ERROR | `{ subsystem:"plugin", phase:"scan", trackIndex?, pluginName?, reason, axErrorCode? }` |
| `set_plugin_preset` error (E16, E18, E20) | ERROR | `{ subsystem:"plugin", phase:"set", trackIndex, pluginName, errorText, axErrorCode? }` |
| `set_plugin_preset` pre-navigation cache-miss on live bundle ID (AC-3.0 step d) | ERROR | `{ subsystem:"plugin", phase:"set", trackIndex, liveBundleID, reason:"no_cache_for_live_plugin" }` |
| `set_plugin_preset` path unresolved in cached tree (AC-3.0 step e) | ERROR | `{ subsystem:"plugin", phase:"set", trackIndex, liveBundleID, path, reason:"path_not_in_cache" }` |
| Cache decode failure on init (AC-2.10) | ERROR | `{ path, error, action:"empty_cache_fallback" }` |
| Cache write failure (E23) | WARN | `{ path, error }` |
| `probeTimeout > 5` in a single scan | WARN | `{ pluginName, probeTimeouts }` |
| Reconciliation failure (AC-2.9) | WARN | `{ trackIndex, pluginName, error }` |
| Plugin identity mismatch on scanner-opened window (AC-5.3) | ERROR | `{ trackIndex, expectedBundleID, actualBundleID }` |

Readable via `log stream --predicate 'subsystem == "plugin"'`.

---

## 8. Testing Strategy

### 8.1 Unit Tests (`Tests/LogicProMCPTests/PluginInspectorTests.swift`)

Target: ≥ 90% line / ≥ 85% branch on `PluginInspector.swift`.

- **`enumerateMenuTree(probe:maxDepth:)`** — 11 tests (adds cycle case, separator, action)
- **`resolveMenuPath(_:in:)`** — 7 tests (leaf depths 1/4, missing, escaped slash, escaped backslash, disambiguated duplicate, empty path)
- **`selectMenuPath(_:)`** — 5 tests (3-hop order, abort on missing intermediate, settle respected, leaf press triggers load, AXPress error propagates)
- **`findPluginWindow` / `identifyPlugin` / `findSettingDropdown`** — 7 tests (happy, no-plugin, bundle-ID match, description fallback, title last-resort, third-party without Setting menu, multiple windows)
- **`openPluginWindow` / `closePluginWindow`** — 5 tests (open happy, appear within timeout, timeout error, close success, close-fails path)
- **`PluginWindowRuntime` seam** — 2 tests asserting timeout tests use injected clock, no real `Thread.sleep`
- **Codable round-trip** — 4 tests (5-level node, cache, inventory, schemaVersion mismatch rejected)

Total: ~41 unit tests.

### 8.2 Integration Tests (`Tests/LogicProMCPTests/AccessibilityChannelPluginTests.swift`)

Target: 100% branch on new handlers.

Per-branch (subset of the full list — all ACs in §3 get ≥ 1 test):

- [x] scan_plugin_presets: no trackIndex + no focused window → error
- [x] scan_plugin_presets: trackIndex + focused window on different track → AC-1.5b (trackIndex wins)
- [x] scan_plugin_presets: trackIndex + window closed → opens, scans, closes
- [x] scan_plugin_presets: trackIndex + window already open → leaves open
- [x] scan_plugin_presets: trackIndex invalid → error
- [x] scan_plugin_presets: track has no instrument → error
- [x] scan_plugin_presets: bundle-ID mismatch post-open → abort + close scanner-opened window (AC-5.3)
- [x] scan_plugin_presets: concurrent call (library scan running) → error via shared flag (AC-1.9)
- [x] scan_plugin_presets: cache hit with matching version → no AX
- [x] scan_plugin_presets: cache entry has version nil → rescan forced (contentHash is NOT used as skip-guard; assert AX calls are made)
- [x] scan_plugin_presets: cache hit with version mismatch → rescan
- [x] scan_plugin_presets: Accessibility perm missing → early error
- [x] scan_plugin_presets: Post-Event perm missing (conditional on T0 outcome) → graceful
- [x] scan_plugin_presets: cache write fails → response still returned (AC-warning path)
- [x] scan_all_instruments: 3 instrument + 2 audio → 3 entries, 2 skipped
- [x] scan_all_instruments: onlyTracks filter
- [x] scan_all_instruments: skipAlreadyCached with partial cache
- [x] scan_all_instruments: 1 track errors, scanner-opened window closed before next (AC-2.8)
- [x] scan_all_instruments: reconciliation close fails → `reconciliationWarnings` populated (AC-2.9)
- [x] scan_all_instruments: pre/post windows-opened-by-scanner delta = 0 (AC-5.5)
- [x] set_plugin_preset: happy path
- [x] set_plugin_preset: plugin identity mismatch pre-click → error (AC-3.0)
- [x] set_plugin_preset: path resolves to action → error (AC-3.3)
- [x] set_plugin_preset: path resolves to separator → error (AC-3.3)
- [x] set_plugin_preset: path resolves to folder → error (AC-3.3)
- [x] set_plugin_preset: window closed before → closed after (AC-3.7 + AC-5.1)
- [x] set_plugin_preset: window open before → open after (AC-5.2)
- [x] set_plugin_preset: during active `scan_plugin_presets` → shared-flag error (AC-1.9)
- [x] resolve_preset_path: cache present path valid → exists:true
- [x] resolve_preset_path: cache present path missing → exists:false
- [x] resolve_preset_path: cache absent → reason:"no_cache"
- [x] resolve_preset_path: trailing slash stripped
- [x] resolve_preset_path: during active scan → returns < 100 ms (no blocking, exempt from flag)

Total: ~33 integration tests.

### 8.3 Edge Case Tests (`Tests/LogicProMCPTests/PluginInspectorEdgeCaseTests.swift`)

One dedicated test per E1–E31 of §5. ≥ 31 tests.

### 8.4 Regression Guard

Existing tests continue to pass; no deletions or weakening.

### 8.5 Live Verification (Manual — `docs/test-live.md` §F2)

Ground truth for G1:
- ES2 Setting menu → leaf count ≥ 300
- Alchemy Setting menu → leaf count ≥ 1 500
- Sculpture Setting menu → leaf count ≥ 250
- Retro Synth Setting menu → leaf count ≥ 200

E2E scripts in `Scripts/plugin-live-e2e.sh`:
- Open ES2 on track 0; `scan_plugin_presets { trackIndex: 0 }`; assert leaf count ≥ 300.
- `set_plugin_preset { trackIndex: 0, path: "Factory Presets/Bass/Sub Bass" }`; visually confirm.
- `scan_all_instruments` on 5-track project; assert `reconciliationWarnings: []` and no windows left open.

---

## 9. Rollout Plan

### 9.1 Migration
- No DB migrations.
- `Resources/plugin-inventory.json` is new; `.gitignore` wildcard `Resources/*-inventory.json` covers both F1 library + F2 plugin per-user caches.

### 9.2 Feature Flag
Not needed. Additive.

### 9.3 Rollback
- `git revert {merge}`.
- `Resources/plugin-inventory.json` on user disk is orphaned post-rollback (not deleted automatically; user can delete manually). Harmless — gitignored, no schema dependents.
- Partial rollback: delete `plugin.*` handlers + dispatcher entries; keep data types for reuse.

---

## 10. Dependencies & Risks

### 10.1 Dependencies

| Dependency | Owner | Status | Risk |
|-----------|-------|--------|------|
| Logic Pro 12 plugin-window header AX stability | Apple | External | Medium |
| Cocoa NSMenu AX response to AXPress | Apple | Shipped | **Low; but T0-validated** |
| AU component registry access (`AudioToolbox`) | Apple | Shipped | Low |
| Existing library-full-enumeration infra | Internal | Shipped v2.1.0 | None |

### 10.2 Risks

| Risk | Prob | Impact | Mitigation |
|------|------|--------|------------|
| **AXPress does NOT work on Logic plugin NSMenu** | Medium | High | **T0 spike gates** — result picks (a) AXPress primary or (b) delegate to `LibraryAccessor.productionMouseClick`. Design §4.1/§4.4 written conditionally; either path is first-class. |
| Apple changes plugin-window header role/description in Logic 12.x | Low | High | Identity via bundle ID is stable across Logic versions. Integration test fails loudly if AX role strings change. |
| AUv3 plugin windows have opaque AX trees | High | Low | Explicit NG3; AC-1.4 requires focused window with Setting dropdown; third-party without one errors cleanly. |
| Scanner leaves plugin windows open after batch crash | Medium | Medium | Batch-level `openedByScanner: [Int: ScannerWindowRecord]` ledger (CGWindowID-keyed close — see AC-2.8) + reconciliation cleanup; on Task.cancel, outer `defer` iterates ledger and closes each via CGWindowID-resolved AXUIElement. |
| Scan finds 30 000 presets and exceeds memory | Low | Medium | `nodeCount` cap 50 000 → error *"plugin menu too large"*. |
| Menu state stale after plugin version update | Low | Low | `pluginVersion` via AU registry (`AudioComponentGetVersion`) is the primary validity axis. Nil version forces rescan (per AC-2.3 + E22). `contentHash` is used only *post-rescan* to confirm the freshly-scanned tree matches the stored hash — never as a skip-guard before scanning. |
| Concurrent user click during scan | Medium | Low | `axScanInProgress` flag + doc note. |
| Actor serializes transport.play behind 30-s scan | Medium | Low | Task.sleep yields; transport queues. Tester wall-clock asserts transport.play returns within `scan p95 + 5s`. |
| macOS watchdog beachball during Alchemy scan | Low | Low | `Task.sleep` yields every AX call; Instruments sample during scan shows main thread responsive. |

---

## 11. Success Metrics

| Metric | Baseline | Target | Method |
|--------|----------|--------|--------|
| Plugin presets discoverable | 0 | ≥ 2 000 on default Logic 12 install | `scan_all_instruments` leaf sum |
| Plugin-surface test coverage | 0% | ≥ 90% line, ≥ 85% branch on `PluginInspector.swift` | `xcrun llvm-cov report` |
| Total test count | baseline | baseline + 50 | `swift test` |
| Wrong-plugin `set_plugin_preset` incidents / 100 calls | 0 | 0 | Manual QA `Scripts/plugin-live-e2e.sh` |
| `scan_plugin_presets` determinism | untested | structurally identical (AC-1.3 axes) | Integration test: decode → strip volatile → assertEqual |
| Build health | PASS | PASS, zero warnings | `swift build && swift test` |

---

## 12. Open Questions

- [x] **OQ-1 (RESOLVED — T0 spike completed live 2026-04-13)**: AXPress on Setting `AXPopUpButton` returns `.cannotComplete -25204` (UI effect happens but response is failure). AXPress on `AXMenuItem` returns `.success 0` and children populate within 200 ms. **Verdict: MIXED** — CGEvent for popup open, AXPress for menu navigation. See `docs/spikes/F2-T0-plugin-menu-probe-result.md`.

- [ ] **OQ-1 (legacy text retained for traceability)**: Does `AXUIElementPerformAction(settingDropdown, kAXPressAction)` work on Logic Pro 12 plugin-window Setting dropdowns? **T0 Checklist** (must all be answered before T1):
  1. Does `AXPress` on the Setting-dropdown `AXMenuButton` open the menu for ES2? Alchemy? DMD?
  2. Does `AXPress` on a submenu `AXMenuItem` populate its children, or is a hover required?
  3. What is the empirical floor for `submenuOpenDelayMs` on Alchemy (slowest)? 100 ms? 300 ms? 500 ms?
  4. After a leaf-click (preset load), is the menu auto-dismissed, or does scanner need to send Escape / click-outside?
  5. What is the `AXIdentifier` / `AXDescription` / `AXTitle` format of the plugin window for ES2 / Alchemy / DMD?
  6. Does opening a plugin window via instrument-slot double-click make the AX-visible window appear within 2000 ms (AC-5.4)?
  7. Does the Setting dropdown have a stable `AXRole` (`AXMenuButton` assumed)?
  8. For third-party AU plugins (NG2 opportunistic): does Logic's Setting menu still appear? If so, same AX layout?
- [ ] **OQ-1 decision cascade**: If T0 answer is NO (AXPress fails), the following sections re-open: §4.1 (Runtime signature), §4.4 (Menu interaction row flips to CGEvent), §6.3 (Post-Event becomes hard-required), E11b (severity upgrades to P0 unconditional), §10.2 risk #1 (already medium; upgrades to certain-high).
- [ ] **OQ-2**: Does Alchemy's Setting menu expose the same factory content as Alchemy's Browse tab? Out of scope v1; `scan_plugin_presets` commits to Setting-menu content only. *Resolution*: manual audit during Phase 5 live verification.
- [ ] **OQ-3**: DMD/DKD per-cell coverage. Deferred to F2.1.
- [ ] **OQ-4** (RESOLVED by v0.4): AU version source. Chosen: `AudioComponentGetVersion(audioComponent, &version)` as primary — a **free function** distinct from `AUPlugInGetVersionNumber` (which requires an instance). Secondary: `AVAudioUnitComponent.versionString` via `AVAudioUnitComponentManager.shared().components(matching:)`. T0 spike validates the chain end-to-end for ES2/Alchemy/DMD + one third-party AU.
- [ ] **OQ-5**: Cache location convention — `Resources/` folder is convention; confirm OK (baseline library uses same).

## 13. Follow-ups (not in scope)

- **F2.1**: Alchemy internal Browse-tab enumeration + DMD/DKD per-cell scan.
- **F2.2**: Effect plugin + MIDI-FX plugin preset enumeration (separate AX surface).
- **F2.3**: `plugin.watch_presets` event stream on user preset save.
- **F2.4**: Fuzzy path matching across plugins (global *"silent caverns"* → `track 3, Alchemy, Pads/Silent Caverns`).
- **F2.5**: Plugin parameter introspection (beyond presets — names/values of all knobs).

---
