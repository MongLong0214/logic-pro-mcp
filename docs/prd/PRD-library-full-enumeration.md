# PRD: Logic Pro Library Full Sound-Pack Enumeration + MCP Mastery

**Version**: 0.3
**Author**: Isaac (via Claude Opus 4.6)
**Date**: 2026-04-12
**Status**: Approved (Phase 2 ALL PASS — strategist/guardian/boomer)
**Size**: XL

### Changelog
- **0.3**: Phase 2 review round 2 — address strategist P1 (L133 diagram contradiction vs L144 prose), strategist P1 (wrong TCC API — IOHIDCheckAccess → `CGPreflightPostEventAccess`), AC-1.7 two-tier scope (Tier A best-effort cache in T1, Tier B proper detection deferred to F5). Plus §7 math clarification, §10.2 stale 90s removal, §11 byte-identical → structural identity, E5b guard window spans settleDelayMs, E15 notes async execute signature.
- **0.2**: Phase 2 review round 1 — address 2 P1 + 10 P2 findings from strategist/guardian/boomer. Key changes: (a) enumerate() shallow semantics preserved (no delegation to enumerateTree), (b) AC-1.7 panel restoration, (c) cycle detection with visited-set, (d) Input Monitoring permission probe, (e) position field not persisted, (f) flatten policy defined, (g) T0 spike for passive AX attribute, (h) Thread.sleep → Task.sleep.

---

## 1. Problem Statement

### 1.1 Background
LogicProMCP's v2.1.0 ships a working Library control path (`library.list`, `track.set_instrument`) but the enumeration only sees the two top-level columns of Logic Pro 12's AXBrowser. Empirical scan of the user's installation produced 259 presets across 13 categories — several categories returned **suspiciously low counts** (Orchestral 2, Guitar 3, Bass 4) that do not match Logic Pro's shipping content. Logic Pro Library is a **tree**, not a flat 2-column list: many categories expand into sub-browsers (e.g. `Orchestral → Strings / Brass / Woodwinds / …`), and inside those sub-columns are more presets. The current MCP cannot see or navigate that tree, so an LLM acting through the MCP cannot reliably ask for "a dark cello patch" or "the 80s analog brass" — it simply does not know those presets exist.

In parallel, the recent set_instrument fix (CGEvent click on track headers) is unit-tested at zero coverage. Every library-related code path added in the last sprint is production-code-only with no regression guard.

### 1.2 Problem Definition
**The MCP cannot enumerate 100 % of the user's Logic Pro Library, and cannot reliably load arbitrary presets onto arbitrary tracks, because (a) its AX browser walker only reads the first two columns of the tree, and (b) the new track-selection + full-scan code has no automated tests.**

### 1.3 Impact of Not Solving
- LLM agents can ask for "a piano patch" but not "the bright suitcase EP" in category `Electric Piano › Rhodes` because the nested presets are invisible.
- The user's demand *"사운드좀 풍부하게 써"* cannot be met — the agent only sees 259 out of likely 2000+ patches on a fully-installed Logic Pro.
- Any future change to `LibraryAccessor.swift` can silently break the Library flow (no tests).
- The inventory JSON under `Resources/` is stale the moment the user installs new Sound Library content.

---

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] **G1**: Enumerate **100 %** of the Library tree reachable from the AXBrowser in the running Logic Pro instance, including arbitrarily deep nested sub-categories, and return a well-typed recursive structure (`LibraryNode`).
- [ ] **G2**: Allow `track.set_instrument` to target any leaf preset by a **path expression** (e.g. `"Orchestral/Strings/Warm Violins"`) so the LLM can unambiguously address nested patches.
- [ ] **G3**: Provide a live `library.scan_all` MCP command whose output has stable **tree structure and names** across back-to-back runs, and completes in **≤ 15 s for the current user installation (~259 presets, 13 categories)** and **≤ 300 s for a 3 000-preset Library** (empirical basis: per-folder settle 500 ms × estimated folder count + leaf enumeration overhead; see §7). `settleDelayMs` caller-tunable.
- [ ] **G4**: Achieve **≥ 90 % line coverage** on `LibraryAccessor.swift` and **100 %** branch coverage on the new `setTrackInstrument` track-selection logic through Swift Testing + XCTest unit tests with a mockable `AXLogicProElements.Runtime` and `LibraryAccessor.Runtime`.
- [ ] **G5**: Add **no fewer than 40 new tests** (unit + integration) covering: recursive enumeration, path resolution, duplicate names, Unicode categories, column-bucket edge cases, CGEvent mouse injection, error propagation, idempotency, and cache staleness.
- [ ] **G6**: All existing 500 tests continue to pass; no production path outside the Library surface is changed.

### 2.2 Non-Goals
- **NG1**: Enumerating non-Library content (Apple Loops browser, Sample Editor, Audio File browser). Those are separate AX surfaces.
- **NG2**: Plugin-preset browsers (Channel EQ presets, Alchemy patches inside the plugin UI). That's a plugin-UI scrape, not a Library scrape.
- **NG3**: Downloading Sound Library content the user has not installed. We only enumerate what is locally installed and visible in the running app.
- **NG4**: Offline Library enumeration without a running Logic Pro instance (the AX tree requires the app to be alive).
- **NG5**: Renaming / editing / tagging Library entries. Read + select only.
- **NG6**: Shipping a pre-built inventory. `Resources/library-inventory.json` is a **per-user artifact**, gitignored going forward; the scanner regenerates it on demand.

---

## 3. User Stories & Acceptance Criteria

### US-1: Exhaustive Library Scan
**As an** LLM agent controlling Logic Pro via MCP, **I want** a single `scan_library` call that returns every category, sub-category, and preset visible in the Library panel, **so that** I can plan a composition using the full palette available to the user.

**Acceptance Criteria:**
- [ ] **AC-1.1**: Given the Library panel is open on a track, when the agent calls `tools/call logic_tracks scan_library`, then the response JSON contains a recursive tree rooted at `categories[]` with each node exposing `{ name, path, kind: "folder" | "leaf", children: [...] }`.
- [ ] **AC-1.2**: Given a category has ≥ 1 nested sub-folder, when the scanner recurses into it, then every leaf preset reachable by clicking through that sub-folder is included in the output at its correct `path`.
- [ ] **AC-1.3**: Given two back-to-back `scan_library` runs with no intervening user action, the emitted JSON is **structurally identical** — same tree shape, same node names at same paths, same node-kind values. Volatile fields (`scanDurationMs`, `generatedAt`) and any transient screen-coordinate data are excluded from the identity contract. Byte-identity is **not** required; diff-safe structural identity is.
- [ ] **AC-1.4**: Given the Library panel is closed, when the agent calls `scan_library`, then the response returns a structured error `"Library panel not found. Open Library (⌘L)"` with `isError: true` and the MCP process does not crash.
- [ ] **AC-1.5**: Given an M-series Mac with Logic Pro 12 at normal responsiveness, when the scanner runs against (a) the current user installation (~259 presets, 13 categories), wall-clock ≤ 15 s p95; (b) a 3 000-preset / 100-folder install, wall-clock ≤ 300 s p95. Both with `settleDelayMs: 500`. The caller may lower `settleDelayMs` at their own risk; response records `measuredSettleDelayMs`.
- [ ] **AC-1.6**: Given the scan completes, when we write the result to `Resources/library-inventory.json`, then the file is valid UTF-8 JSON, round-trips through `JSONDecoder().decode(LibraryRoot.self, from:)`, contains **no screen-coordinate data**, and is gitignored.
- [ ] **AC-1.7 (two-tier)**:
  - **Tier A (best-effort, in scope for T1)**: Scanner opportunistically caches the last `selectCategory`/`selectPreset` pair routed through `LibraryAccessor` during the current `AccessibilityChannel` lifetime. If that cache is non-empty at scan start, the scanner re-clicks category+preset after the scan and sets `"selectionRestored": true`. Otherwise it sets `"selectionRestored": false`. This path is **testable** in T1 because it does not depend on reading Logic's visible-selection state (which `detectSelectedText` cannot provide — see LibraryAccessor.swift:258-265 comment).
  - **Tier B (deferred follow-up F5)**: True selection detection via an improved AX probe (candidates: private AXBrowser selected-row attribute, Scripter-side query, or MCU feedback). Blocked on spike; not required for T1 PASS.
  - Test plan §8.2 "AC-1.7 restored after success/error" **references Tier A only** and asserts `selectionRestored: true` iff the client previously routed a `selectCategory` through MCP in the same session.
- [ ] **AC-1.8**: Given `Task.sleep` (not `Thread.sleep`) is used between column clicks, when the scan runs inside the `AccessibilityChannel` actor, then the actor thread is **not** blocked and other actor messages (e.g. `transport.play`) remain serviceable — though actual AX calls serialize against the scan via §5 E15 lock.

### US-2: Path-Addressed Preset Load
**As an** LLM agent, **I want** to call `set_instrument` with a **path** like `Orchestral/Strings/Warm Violins` instead of only `{ category, preset }`, **so that** I can target nested presets unambiguously.

**Acceptance Criteria:**
- [ ] **AC-2.1**: Given a valid path `"A/B/C"` where `A` is a top-level category, `B` a sub-folder, and `C` a leaf preset, when the agent calls `set_instrument { index, path }`, then LibraryAccessor navigates the tree by clicking `A`, then `B`, then `C`, and returns `{ "category":"A", "preset":"C", "path":"A/B/C" }`.
- [ ] **AC-2.2**: Given a path where the leaf does not exist, when the call is made, then the response is `{ isError: true, text: "Preset not found at path: A/B/Nope" }`.
- [ ] **AC-2.3**: Given the legacy `{ category, preset }` shape is provided, when the handler runs, then backward-compatible behaviour is preserved (routes through the same path: `"category/preset"`).
- [ ] **AC-2.4**: Given a path contains a slash-looking character inside a real preset name (e.g. a preset literally named `"Bass / Sub"`), when the caller escapes it as `"Bass\\/Sub"` in the path, then the parser un-escapes before lookup.
- [ ] **AC-2.5**: Given `index` is out of range for the current project, when the call runs, then the handler returns `{ isError: true, text: "Track at index N not found" }` **without** mutating the Library selection.
- [ ] **AC-2.6**: Given a `resolve_path` call with argument `path: "A/B/C"`, when the resolver runs, then the response is `{ exists: Bool, kind: "folder" | "leaf" | null, matchedPath: String?, children: [String]? }`. `children` is populated only when `kind == "folder"`. No click is injected; the function is read-only.
- [ ] **AC-2.7**: Given a path ends with `/` (e.g. `"Bass/"`), when the resolver runs, then the trailing slash is stripped and treated as a folder lookup. If the resulting node is a leaf, `kind: "leaf"` is returned — no error.
- [ ] **AC-2.8**: Given `set_instrument` is called with `path` that resolves to a **folder**, not a leaf, when the handler runs, then the response is `{ isError: true, text: "Path resolves to a folder, not a preset: <path>" }`.

### US-3: Track-Selection Correctness
**As an** LLM agent, **I want** `set_instrument` to actually load the preset onto the track I named, **so that** my multi-track arrangements are not clobbered by the previously-selected track receiving every new instrument.

**Acceptance Criteria:**
- [ ] **AC-3.1**: Given tracks 0 … 7 exist and track 5 is currently selected, when I call `set_instrument { index: 0, path: "Bass/Sub Bass" }`, then **track 0** (not track 5) becomes the instrument host.
- [ ] **AC-3.2**: Given the track header is partially or fully scrolled off-screen (computed click Y is above the tracklist top or below its bottom), when `set_instrument` is called, then the handler returns `{ isError: true, text: "Track not visible; scroll tracklist to bring track N into view" }` **without** mutating the Library. The handler **does not** attempt to auto-scroll. (Aligned with E13.)
- [ ] **AC-3.3**: Given `findTrackHeader(at: index)` returns nil (track deleted mid-operation), when the handler runs, then we return `isError: true` and do **not** proceed to click the Library.

### US-4: Recursive Enumeration Robustness
**As a** maintainer, **I want** `LibraryAccessor.enumerateTree()` to be fully deterministic and cycle-safe, **so that** bugs in Logic Pro's AX tree cannot cause the MCP to hang or emit garbage JSON.

**Acceptance Criteria:**
- [ ] **AC-4.1**: Given an AX tree of depth 10+, when `enumerateTree()` runs, then it enforces `maxDepth: 12` and returns a truncated branch flagged `"truncated": true` at depth 12 instead of infinite-recursing.
- [ ] **AC-4.2**: Given two sibling nodes with identical `name`, when they are enumerated, then both survive in the tree with `path` disambiguated by position index (e.g. `"Synthesizer/Pad[0]"`, `"Synthesizer/Pad[1]"`).
- [ ] **AC-4.3**: Given a node's `AXValue` is empty string or whitespace-only, when the walker reads it, then that node is **skipped** (not emitted) and a counter is incremented in the debug log.
- [ ] **AC-4.4**: Given the scanner encounters a node it clicked but whose column 2 never populates within 800 ms, when timeout elapses, then that branch returns `children: []` with `"probeTimeout": true` marker and the scan continues to the next sibling.

### US-5: Test Coverage Mandate
**As a** maintainer, **I want** every new function and every new branch to have at least one unit test or integration test, **so that** regressions in the Library surface are caught before shipping.

**Acceptance Criteria:**
- [ ] **AC-5.1**: Given `swift test` runs to completion, when we compute per-file coverage with `llvm-cov`, then `LibraryAccessor.swift` shows ≥ 90 % line coverage and ≥ 85 % branch coverage.
- [ ] **AC-5.2**: Given the test suite, when we count tests added under this PRD, then the added count is ≥ 40 and every new public function has at least one test whose name explicitly references it.
- [ ] **AC-5.3**: Given all tests run, when final tally is reported, then total project tests are ≥ 540 (500 baseline + 40 new) and **zero** existing tests are deleted or weakened.

---

## 4. Technical Design

### 4.1 Architecture Overview

```
MCP Dispatcher (TrackDispatcher.swift)
   │
   ├── "scan_library"       ──▶ router.route("library.scan_all")
   ├── "set_instrument"     ──▶ router.route("track.set_instrument", { index, category?, preset?, path? })
   └── "list_library"       ──▶ router.route("library.list")
          │
          ▼
ChannelRouter — routes [.accessibility]
          │
          ▼
AccessibilityChannel
   ├── listLibrary                — shallow (current category only)
   ├── scanLibraryAll             — recursive tree
   └── setTrackInstrument         — resolves path OR {category, preset}, clicks track, clicks browser
          │
          ▼
LibraryAccessor (new recursive layer)
   ├── enumerateTree(maxDepth:)              → LibraryNode
   ├── resolvePath(_: String) -> ClickPath?  → [CGPoint] to click in order
   ├── selectByPath(_:)                      → navigates and clicks
   ├── currentPresets()                      → existing helper
   ├── enumerateAll()                        → preserved AS-IS; shallow depth-1 walker, clicks top-level categories only; NOT a wrapper over enumerateTree
   └── productionMouseClick(at:)
          │
          ▼
AXLogicProElements / AXHelpers (unchanged)
```

Key change: `LibraryAccessor.Inventory` (flat `[String: [String]]`) is **augmented** (not replaced) by `LibraryAccessor.LibraryNode` (recursive).

**Critical clarification (addresses strategist P1-1):**
- `enumerate()` **KEEPS its current shallow, click-free semantics**. It reads whatever columns are already visible in the Library panel without injecting any click. It is **NOT** a wrapper over `enumerateTree()`. Callers of `list_library` command (router: `library.list`) see identical behaviour to today: fast (< 50 ms), side-effect-free, only-current-category visibility.
- `enumerateAll()` is the existing **shallow-recursive** variant that clicks through top-level categories (depth-1 traversal). It is retained for legacy tests that exercise its specific 2-column flattening behaviour. It is **NOT** renamed or delegated.
- `enumerateTree(maxDepth:)` is the **NEW** deep-recursive walker introduced by this PRD, wired to `library.scan_all` only. `list_library` is **never** routed through it.

**Flatten policy for Inventory (addresses boomer P2-3):**
When producing the legacy-shape `Inventory.presetsByCategory` from a recursive scan, the rule is: **every leaf node (kind: "leaf") that is a descendant of a top-level category node — at any depth — is flattened into that category's preset array, in depth-first in-order traversal order**. Folder nodes never appear in `presetsByCategory`. Leaves at nested paths carry only their leaf `name` into the flat array; the full path is preserved only in the companion `root: LibraryNode`. A dedicated test verifies the flatten invariant.

### 4.2 Data Model Changes

New Swift types (all `Sendable`, `Codable`):

```swift
enum LibraryNodeKind: String, Codable, Sendable {
    case folder        // has children, clicking it reveals a new column
    case leaf          // a loadable preset
    case truncated     // depth cap hit
    case probeTimeout  // clicked but column did not populate
}

struct LibraryNode: Codable, Sendable, Equatable {
    let name: String           // raw AXValue
    let path: String           // "/"-joined from root; disambiguated with [i] on duplicate siblings
    let kind: LibraryNodeKind
    let children: [LibraryNode]
    // NOTE: screen-coordinate data is NOT persisted on LibraryNode.
    // Coordinates are resolved live by `resolvePath()` at click-time against
    // the current AX tree, so window-move / window-resize between a scan and
    // a later `selectByPath` call cannot cause click-position drift.
}

struct LibraryRoot: Codable, Sendable, Equatable {
    let generatedAt: String        // ISO-8601; excluded from AC-1.3 identity
    let scanDurationMs: Int        // excluded from AC-1.3 identity
    let measuredSettleDelayMs: Int // excluded from AC-1.3 identity
    let selectionRestored: Bool
    let truncatedBranches: Int
    let probeTimeouts: Int
    let nodeCount: Int
    let leafCount: Int
    let folderCount: Int
    let root: LibraryNode
    let categories: [String]
    let presetsByCategory: [String: [String]] // flatten policy: see §4.1
}
```

**Why no `position` in JSON (addresses boomer P2-2):** Absolute screen coordinates depend on window placement. Persisting them means any user window move between scan and subsequent click invalidates the cache — catastrophic silent mis-click. The single source of truth for click position is the **live AX tree at click time**; `resolvePath()` re-traverses categories by name, reads `kAXPosition`+`kAXSize` fresh, and clicks.

`Inventory` gains a companion root: `{ root: LibraryNode, categories: [...], presetsByCategory: {...}, generatedAt: ISO8601 }`.

JSON example:

```json
{
  "generatedAt": "2026-04-12T18:00:00Z",
  "scanDurationMs": 12430,
  "measuredSettleDelayMs": 500,
  "selectionRestored": true,
  "truncatedBranches": 0,
  "probeTimeouts": 0,
  "nodeCount": 347,
  "leafCount": 259,
  "folderCount": 88,
  "root": {
    "name": "(library-root)",
    "path": "",
    "kind": "folder",
    "children": [
      { "name": "Orchestral", "path": "Orchestral", "kind": "folder",
        "children": [
          { "name": "Strings", "path": "Orchestral/Strings", "kind": "folder",
            "children": [
              { "name": "Warm Violins", "path": "Orchestral/Strings/Warm Violins", "kind": "leaf" }
            ]
          }
        ]
      }
    ]
  },
  "categories": ["Orchestral", "…"],
  "presetsByCategory": { "Orchestral": ["Warm Violins", "…"] }
}
```

### 4.3 API Design

| Method | Tool name | Command | Params | Description |
|--------|-----------|---------|--------|-------------|
| MCP tool | `logic_tracks` | `list_library` | `{}` | (unchanged) Shallow enum of currently-shown columns. |
| MCP tool | `logic_tracks` | `scan_library` | `{ maxDepth?: Int, settleDelayMs?: Int }` | **NEW** full recursive scan. Returns `LibraryNode` tree. |
| MCP tool | `logic_tracks` | `set_instrument` | `{ index: Int, path?: String, category?: String, preset?: String }` | **EXTENDED** — `path` preferred; `{category, preset}` legacy. |
| MCP tool | `logic_tracks` | `resolve_path` | `{ path: String }` | **NEW** dry-run: reports whether a path exists without clicking. Useful for the LLM to validate before committing. |

All commands route through `.accessibility` channel. No new channels.

### 4.4 Key Technical Decisions

**Depth terminology — clarification (addresses strategist P2-1):**
Two distinct depth concepts appear in this PRD and in the existing code:
- **AX-tree depth**: raw descendant depth in the macOS Accessibility hierarchy. `findAllDescendants(maxDepth: 6)` in `LibraryAccessor.swift:47` refers to this.
- **Library-tree depth**: depth of the conceptual Library browser (category → subfolder → preset). This is what PRD §3 AC-4.1's `maxDepth: 12` refers to.

AX-tree depth is incidental to MCP behaviour and remains bounded by `AXHelpers.findAllDescendants`' own caps. Library-tree depth is the semantic contract. All further references to "depth" in this PRD mean Library-tree depth unless explicitly stated.

**Settle-delay scope — clarification (addresses boomer S3 P2-1 performance math):**
`settleDelayMs` is applied **per folder-click only** (clicking a category or a subfolder to expand it). It is **NOT** applied after leaf reads — leaf enumeration is a single AX-tree walk of the newly-revealed column with no further clicks. Perf formula: `T ≤ (folderClickCount × settleDelayMs) + (leafCount × leafReadMs)` where `leafReadMs ≤ 15 ms` on M-series.

| Decision | Options Considered | Chosen | Rationale |
|----------|-------------------|--------|-----------|
| Tree representation | (a) flat `[path: position]` map, (b) recursive `LibraryNode` | (b) | Matches Logic's UX, path expressions stay human-readable, LLMs parse trees well. |
| Recursion strategy | (a) pre-scan all columns then diff, (b) click → observe → recurse, (c) read passive AX attribute if it exposes tree | (b) with (c) as T0 spike prerequisite | Logic's AX known to require clicks for column population; (c) is a potential big-win shortcut investigated in T0 — see §12 OQ-4 promotion. |
| Depth cap | (a) unlimited with cycle detection, (b) hard `maxDepth=12` + visited-element set | (b) | Logic's real Library-tree depth ≤ 6; 12 leaves headroom; visited-set protects against AX-bug re-emission regardless of depth. |
| Duplicate-name siblings | (a) dedupe silently, (b) disambiguate with `[i]` suffix | (b) | User might have custom patches with identical names; silent dedupe = data loss. |
| Path escape char | (a) URL-encode, (b) backslash-slash (`\/`) | (b) | Rarer in preset names, easier to read, matches JSON-style. |
| Inventory location | (a) gitignored `Resources/library-inventory.json`, (b) `~/Library/Application Support/LogicProMCP/` | (a) | Keeps per-project cache simple; the file is ignored, not shipped. |
| Position data persistence | (a) embed CGPoint in LibraryNode JSON, (b) never persist — always re-query live | (b) | Window moves would otherwise invalidate cache silently. See §4.2 note. |
| Track selection | (a) `AXPressAction`, (b) CGEvent mouse click on header position | (b) | Empirically proven Apr 12 — AXPressAction is ignored by Logic on AXLayoutItem, CGEvent click works. |
| Test mocking | (a) inject a `Runtime` struct of closures, (b) swap the AX APIs in a protocol | (a) | Already the pattern in `AXHelpers.Runtime`; consistency over novelty. |
| Click probe | Before declaring `probeTimeout`, how long to wait | 800 ms settle, 4 polls of 200 ms | Matches the slowest observed Logic column update on M-series. |
| Cache determinism | (a) sort alphabetically, (b) preserve AX order | (b) | AX order matches what the user sees; sorting would lie. AC-1.3 weakened to structural identity (name+path+kind), not byte identity, to tolerate any trace-level AX ordering variance. |
| Legacy `enumerate()` | (a) delete, (b) keep as wrapper over enumerateTree, (c) preserve as-is (click-free) | (c) | Strategist P1-1 — (b) would change perf profile and side-effect profile of `list_library` from free-read to multi-second-tree-walk. (c) preserves semantics. |
| Sleep semantics | (a) `Thread.sleep`, (b) `Task.sleep` | (b) for new recursive scanner | Recursive scan in actor-backed `AccessibilityChannel`; `Thread.sleep` would block the actor. `enumerateAll` (legacy top-level-only) retains `Thread.sleep`; only `enumerateTree` uses async. |

---

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | Library panel closed | Structured error: `"Library panel not found"`; no crash | P1 |
| E2 | Category has 0 presets | Node emitted with `children: []` and `kind: folder` | P3 |
| E3 | Two siblings named identically | Both emitted with `path` disambiguator `[0]`, `[1]` | P2 |
| E4 | Preset name contains `/` | Path escapes as `\/`; decoder unescapes | P2 |
| E5 | AX tree mutates mid-scan (user opens a plugin) | Scan aborts with `"Library tree changed during scan"`; partial tree NOT written to cache | P1 |
| E5b | AX tree mutates mid-scan because the **scanner itself** clicks a category (expected) | Scanner's own clicks do NOT trigger E5 — only clicks originating outside the scanner's click-sequence do. Differentiate by setting a `scannerClickInFlight` guard that spans **from the moment `postMouseClick` is posted until the subsequent `currentPresets` read completes** (i.e. at least `settleDelayMs` + 50 ms read, **not** a fixed 250 ms — the 250 ms in previous draft was an error). The guard window strictly covers one scanner click-and-read cycle. | P2 |
| E5c | Logic Pro window **loses focus** to another app mid-scan | Scanner detects focus loss via `AXUIElementCopyAttributeValue kAXFocusedApplicationAttribute`; aborts with `"Library scan aborted: Logic Pro lost focus"`; scan state rolled back via §AC-1.7 restoration. | P2 |
| E6 | Unicode / RTL category names (e.g. Hebrew, emoji) | Preserved byte-for-byte in JSON; `JSONEncoder` handles it | P2 |
| E7 | Column never populates after click (Logic AX bug) | Node marked `kind: probeTimeout`, scan continues | P2 |
| E8 | Depth > 12 | Branch truncated, `kind: truncated` marker, log warning | P2 |
| E8b | AX re-emits same AXUIElement at deeper path (cycle) | Scanner keeps a `Set<AXUIElementHash>` of visited element IDs; on revisit the branch terminates with `kind: cycle` marker and `cycleCount++` in root. | P2 (addresses guardian P2-1 cycle safety) |
| E9 | Logic Pro not running | Scan returns `"Logic Pro is not running"` (reuses existing appRoot check) | P1 |
| E10 | MCP process has no Accessibility permission | `AXTrustedCheckOptionPrompt`/`AXIsProcessTrusted()` probe at start — returns `"Accessibility permission required; grant in System Settings → Privacy & Security → Accessibility"` | P0 |
| E10b | MCP process has Accessibility permission but **no Post-Event capability** (needed for `CGEvent.post`) | First `CGEvent.post` silently no-ops on macOS 10.15+ if Post capability is denied. Detect via **`CGPreflightPostEventAccess()`** (correct API for posting; `CGPreflightListenEventAccess()` covers event *taps*, which we don't use). If false, call `CGRequestPostEventAccess()` once to surface the system prompt, then fail with `"Event-post permission required; approve in System Settings → Privacy & Security → Accessibility (Input Monitoring subsection if present)"`. Do NOT use `IOHIDCheckAccess` — that is IOHIDManager listen path and targets a different capability. (addresses guardian P2-2 + strategist Round 2 P1) | P0 |
| E11 | `set_instrument` with both `path` and `{category, preset}` | `path` wins; ignore others; log DEBUG note | P3 |
| E12 | `set_instrument` with neither `path` nor `{category, preset}` | `isError: true`, text: `"Missing path or (category+preset)"` | P1 |
| E13 | Track scroll position hides target header | Attempt to CGEvent click at computed position; if off-screen (y < window top), return explicit `"Track not visible; scroll tracklist"` error | P2 |
| E14 | User has 0 Sound Library content installed | `categories: []`, `presetsByCategory: {}`, root with empty children | P3 |
| E15 | Concurrent `scan_library` calls | Second call returns `"Library scan already in progress"`. **Concrete mechanism** (addresses guardian P2-3 + boomer Phase 6 P2): `AccessibilityChannel` gains an isolated `private var scanInProgress: Bool` actor state. The `case "library.scan_all":` branch in `execute` **must become `async`** (to permit the inner `Task.sleep` required by AC-1.8) and checks-and-sets this flag **within the same actor step** before awaiting anything (atomic by actor isolation — no suspension point between check and set). The flag is cleared in a `defer` block inside the scan implementation. Note: `execute` signature change from `func execute(...) -> ChannelResult` to `func execute(...) async -> ChannelResult` is an existing fact (AccessibilityChannel.swift: case statements already `await`). A test forces two concurrent `route("library.scan_all")` calls and asserts exactly one succeeds while the other errors. | P1 |
| E16 | AX call returns axError code (-25205 etc.) | Wrap in `.error(description)`; do not panic | P1 |
| E17 | Cache file write fails (permissions / disk full) | Scan result still returned to MCP caller; write failure logged; `cachePath` omitted from response | P2 |
| E18 | LibraryAccessor called before Logic window exists | `mainWindow() == nil` → `.error("Logic Pro window not found")` | P1 |
| E19 | `AXValueGetValue` force-unwrap crash risk (`posRaw as! AXValue`) | All `as!` on AX values replaced with `as? AXValue` + guard; nil returns `.error("AX position data unavailable")`. Existing force-unwraps in `LibraryAccessor.swift:250-251` and `AccessibilityChannel.swift:824-825` are fixed in T1. (addresses guardian Phase 6 P2) | P1 |
| E20 | `path` param contains empty segment (e.g. `"A//C"`) | Parser collapses consecutive slashes OR errors; choose: **error** `"Invalid path: empty segment"` — less surprising. | P3 |
| E21 | Track row AX index drifts after user deletes a track mid-session | Client is responsible for re-fetching track list between mutations. MCP returns whatever AX reports at call time. Documented in AGENTS.md. | P3 |
| E22 | User has > 1 Library panel open (detached / split view) | `findLibraryBrowser` returns the first AXBrowser with description "Library"/"라이브러리". Second panel is ignored. Log at INFO. | P3 |

---

## 6. Security & Permissions

### 6.1 Authentication
N/A — MCP is a local stdio process bound to the user running Claude.

### 6.2 Authorization

| Role | scan_library | set_instrument | list_library | resolve_path |
|------|--------------|---------------|--------------|--------------|
| MCP caller (local user) | ✓ | ✓ | ✓ | ✓ |

No multi-user model. Access is gated by macOS Accessibility permission at the OS level.

### 6.3 Data Protection & Permission Model
- Inventory JSON contains preset names only (no user content, no audio, no PII).
- Cache file written to `Resources/library-inventory.json` with `0644`; same trust zone as the binary.
- **CGEvent mouse injection** is equivalent in risk profile to what Logic Pro automation apps (Keyboard Maestro, BetterTouchTool) already do. Documented in `SECURITY.md`.
- No new network egress. No telemetry.

**macOS TCC permissions required (addresses guardian P2-2):**

| Permission | Purpose | Detection | Missing → behaviour |
|-----------|---------|-----------|---------------------|
| Accessibility | `AXUIElementCopyAttributeValue`, tree traversal, `AXValueGetValue` | `AXIsProcessTrusted()` | Fail fast with clear error before any scan starts |
| Post-Event (Accessibility subsection on macOS) | `CGEvent.post(tap: .cghidEventTap)` — our only use of CGEvent | **`CGPreflightPostEventAccess()`** (`CoreGraphics/CGEvent.h`, macOS 10.15+). Do **not** use `IOHIDCheckAccess` (listen path; wrong capability). If the preflight returns false, call `CGRequestPostEventAccess()` once — the first call triggers the system prompt; subsequent behaviour is gated by user choice. | Fail with `"Event-post permission required"` and link to System Settings → Privacy & Security → Accessibility |

Both permissions are surfaced via the existing `system.permissions` MCP tool so the caller can pre-flight.

---

## 7. Performance & Monitoring

**Formula (settle-delay math, addresses boomer B1/S3 P2):**
```
T_scan ≈ folderClickCount × settleDelayMs   (every folder click, including top-level categories)
       + leafCount × leafReadMs              (AX column read — no click applied to leaves)
       + overhead                            (JSON encode, logging ~100 ms)
```
`folderClickCount` counts **every folder-kind node the scanner must click to expose its children** — top-level categories are folders and are counted here; they are **not** double-counted elsewhere. For `settleDelayMs=500`, `leafReadMs≤15` (M-series):
- **Current user** (13 top-level categories, 0 documented subfolders, 259 leaves): `folderClickCount = 13`. `13 × 500 + 259 × 15 ≈ 10.4 s`. Target **≤ 15 s p95** with settle = 500 ms has ~4.6 s headroom.
- **Larger install** (100 folders across 3 Library-tree levels, 3 000 leaves): `folderClickCount = 100`. `100 × 500 + 3 000 × 15 ≈ 95 s`. Target **≤ 300 s p95** leaves > 3× headroom for probe-timeout retries and AX slowness.

| Metric | Target | Measurement |
|--------|--------|-------------|
| scan_library wall time (current user: ~259 presets, 13 categories) | ≤ 15 s p95 | `scanDurationMs` in `LibraryRoot` |
| scan_library wall time (3 000 presets, 100 folders across 3 levels) | ≤ 300 s p95 | same |
| set_instrument end-to-end (path mode) | ≤ 2 s p95 | server-side timer |
| Per-folder-click settle delay | `settleDelayMs` (default 500 ms, caller-tunable 200–2000 ms) | `measuredSettleDelayMs` in `LibraryRoot` |
| Memory peak during scan | < 50 MB incremental | `os_proc_available_memory()` sample |
| Max Library-tree depth processed | 12 | hard-coded `maxLibraryDepth` constant |
| Visited-element cycle guard set capacity | ≤ 10 000 entries | sanity check in test E8b |

### 7.1 Monitoring & Alerting

- Every `scan_library` run logs at `INFO`: `subsystem: "library"`, keys `{ nodeCount, leafCount, folderCount, durationMs, truncatedBranches, probeTimeouts }`.
- Every `set_instrument` path call logs at `DEBUG` the resolved click sequence.
- On `probeTimeout` > 5 in a single scan, log at `WARN` — signals Logic Pro AX degradation.
- No external alerting (local tool). Log lines are readable via `log stream --predicate 'subsystem == "library"'`.

---

## 8. Testing Strategy

### 8.1 Unit Tests (Swift Testing, `Tests/LogicProMCPTests/LibraryAccessorTests.swift`)

Mandatory coverage per-function:

- `enumerateTree(maxDepth:)` — 8 tests
  - Happy path: 2-level tree, 3 categories × 2 leaves each → 6 leaf nodes
  - Deep tree: 6-level chain with single branch per level
  - maxDepth enforcement: depth=2 on a 5-level tree → truncated at 2
  - Duplicate siblings: `["Pad", "Pad"]` → `[path="…/Pad[0]", path="…/Pad[1]"]`
  - Empty category: folder with 0 children → `kind: folder, children: []`
  - Whitespace-only names: skipped
  - Column probe timeout: stub that never populates → `kind: probeTimeout`
  - Cycle safety: stub that returns self on click → depth cap hits first
- `resolvePath(_:)` — 6 tests
  - Leaf at depth 1: `"Bass/Sub"` resolves
  - Leaf at depth 3: `"Orch/Str/Warm"` resolves
  - Missing leaf: returns nil
  - Escaped slash: `"Bass\\/Sub"` targets literal `"Bass/Sub"` child of root
  - Disambiguated duplicate: `"Synth/Pad[1]"` picks the second sibling
  - Empty path: returns nil
- `selectByPath(_:)` — 4 tests
  - Two-hop click sequence is posted in order
  - Abort on missing intermediate node
  - Settle delay respected between clicks
  - Legacy `{category, preset}` path continues to work
- `currentPresets()` — 3 tests
  - 2-column snapshot returns column 2
  - 1-column snapshot returns `[]`
  - 3-column snapshot returns the deepest populated column
- Inventory Codable — 3 tests
  - Round-trip a 5-level LibraryNode via JSONEncoder/Decoder
  - Decoder rejects malformed JSON
  - Stable ordering: same tree → same JSON bytes
- `productionMouseClick(at:)` — 2 tests
  - Two CGEvents posted (down, up) in order via injected `postMouseClick` closure
  - nil CGEventSource returns false

### 8.2 Integration Tests (`Tests/LogicProMCPTests/AccessibilityChannelLibraryTests.swift`)

Target: **100 % branch coverage** on `AccessibilityChannel.setTrackInstrument` and new `scanLibraryAll`. `LibraryAccessor.swift` ≥ 90 % line / ≥ 85 % branch (§8.1). Split is explicit (addresses strategist P2-4):

Per-branch test plan for `setTrackInstrument`:
- [x] `index` absent → category+preset path legacy
- [x] `index` present, header found, posValue path → CGEvent click
- [x] `index` present, header found, posValue absent → fallback `AXPressAction` path
- [x] `index` present, header **NOT** found → return error before any library click
- [x] `path` param present → resolvePath + selectByPath, no category/preset used
- [x] `path` present AND `{category, preset}` present → path wins, others ignored
- [x] `path` absent AND `category` or `preset` absent → error
- [x] `path` resolves to a folder (not leaf) → error (AC-2.8)
- [x] Category lookup fails → error
- [x] Preset lookup fails → error
- [x] AC-3.2 off-screen header → error without mutating Library
- [x] E19 `AXValue` force-unwrap replaced with `as?` guard → handled nil path
- [x] E10b Input Monitoring denied → early error

Per-branch test plan for `scanLibraryAll`:
- [x] Happy path 3-category × 2-level
- [x] Panel closed → error
- [x] E15 concurrent scan → second call errors via actor state
- [x] E5 AX mutation mid-scan → abort
- [x] E5c focus loss → abort + restore
- [x] AC-1.7 selection restored after success
- [x] AC-1.7 selection restored after error
- [x] Cache write failure tolerated; response still returned
- [x] JSON schema compliance (decode `LibraryRoot`, assert fields)
- [x] Flatten policy: 3-level tree produces correct `presetsByCategory`
- [x] `selectionRestored: false` path (pre-scan detection failed)

### 8.3 Edge Case Tests (`Tests/LogicProMCPTests/LibraryAccessorEdgeCaseTests.swift`)

Every row E1–E22 of §5 has a dedicated test. (≥ 22 tests.)

### 8.4 Regression Guard

- Existing `LibraryAccessor.enumerate()` behaviour: add 1 test per legacy contract (≥ 3 tests).
- Full `swift test` must show ≥ 540 tests passing.

### 8.5 Live Verification (Manual, documented in `docs/test-live.md`)

- Run `Scripts/live-e2e-test.sh scan_library` with Logic Pro open → confirm ≥ 2× current preset count on a fresh install.
- Load 8 different instruments on 8 tracks via `Scripts/load-8-instruments.py`, verify visually.
- Load a depth-3 preset (e.g. `Orchestral/Strings/<something>`) via path mode.

---

## 9. Rollout Plan

### 9.1 Migration Strategy
- No DB migrations. 
- `Resources/library-inventory.json` behaviour changes: it is now regenerated by `scan_library`, no longer shipped. Add `Resources/library-inventory.json` to `.gitignore` and delete the checked-in copy.
- Existing MCP consumers calling `set_instrument { category, preset }` keep working (backwards-compat shim converts to `path: "category/preset"`).

### 9.2 Feature Flag
Not needed. This is additive. The new `scan_library` + `path` parameter are opt-in; nothing legacy breaks.

### 9.3 Rollback Plan
- `git revert {this merge commit}` — no external state to undo.
- If rollback is partial (keep scan, drop path param), delete the `path` arg handling in `setTrackInstrument` and keep `scan_library`.

---

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if Delayed |
|-----------|-------|--------|-----------------|
| Logic Pro 12 AXBrowser structural stability | Apple | External | Medium — Apple could change AX tree shape in a 12.x update |
| swift-testing ≥ 0.12 | swiftlang | Shipped | None |
| Running Logic Pro instance for manual QA | Isaac | Available | None |

### 10.2 Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Apple changes AXBrowser role names in Logic Pro 12.x | Low | High | Keep `findLibraryBrowser` role search generous (already fallbacks to first AXBrowser in window); add integration test that fails loudly if role strings change. |
| CGEvent mouse injection suppressed by future macOS security change | Low | Critical | Document dependency in SECURITY.md; add runtime check that logs a clear error if `CGEvent.post` silently fails. |
| Recursive scan hangs on AX tree with unexpected cycle | Medium | Medium | `maxDepth=12` hard cap + `probeTimeout` per click. |
| Users with huge Sound Library (5 000+ patches) exceed the 300 s budget | Low | Low | Expose `settleDelayMs` parameter; document that large libraries may need `--max-scan-seconds` bump (P1 follow-up, not blocking). |
| Test mocks drift from real AX behaviour | Medium | Medium | Keep one live-validation script in `Scripts/` that runs against a real Logic Pro as part of release checklist. |
| User concurrent clicking during scan perturbs results | Medium | Low | AccessibilityChannel-level scan lock + doc note to user "don't touch Logic during scan". |
| set_instrument with path "A/B" where B is a folder (not leaf) | Medium | Medium | Explicit error: `"Path resolves to a folder, not a preset; use scan_library to find leaves"`. |

---

## 11. Success Metrics

| Metric | Baseline | Target | Measurement Method |
|--------|----------|--------|--------------------|
| Presets discoverable via MCP | 259 | ≥ 2 × baseline on a default-install Logic Pro | `scan_library` response leaf count |
| Library-surface test coverage | 0 % on new functions | ≥ 90 % line, ≥ 85 % branch | `xcrun llvm-cov report` |
| Total test count | 500 | ≥ 540 | `swift test` output |
| Wrong-track set_instrument incidents per 100 calls | unknown (1/1 in last test) | 0 | manual QA script `Scripts/load-8-instruments.py` |
| scan_library determinism | untested | structurally identical (name+path+kind) across back-to-back runs | integration test: JSON decode → strip volatile fields (`generatedAt`, `scanDurationMs`, `measuredSettleDelayMs`) → `assertEqual` on normalized tree |
| Build health | 500/500 PASS | 540+/540+ PASS, zero warnings | CI-equivalent `swift build && swift test` |

---

## 12. Open Questions

- [ ] **OQ-1**: Does the user's Logic Pro actually have nested sub-folders inside `Orchestral`, `Guitar`, `Bass` categories? If no, the 259 number is already 100 %, and the recursive walker still ships but surfaces depth=1 trees. **Resolution path**: resolved during Phase 5 TDD when we run the live scanner against the real Logic.
- [ ] **OQ-2**: Should `scan_library` also enumerate the **Patch Settings** (Smart Controls configuration per preset)? Marked Non-Goal for now; flag as P2 follow-up.
- [ ] **OQ-3**: Should we expose a `library.watch_changes` MCP event that fires when the user installs new Sound Library content? Out of scope for this PRD; see §13 Follow-ups.
- [ ] **OQ-4 (PROMOTED to T0 spike — addresses boomer B1 UNVALIDATED assumption)**: Is there an AX attribute (`kAXColumnsAttribute`, `kAXVisibleColumnsAttribute`, `kAXRowsAttribute`, or a custom private attribute) on `kAXBrowserRole` that exposes the entire Library tree passively without mouse clicks? **Why this must be answered before design locks**: if YES, the click-based recursive walker is replaced by a single attribute read — scan drops from ~15-300 s to < 1 s, eliminates Input Monitoring dependency, eliminates window-state dependency, eliminates cycle/visited-set complexity. If NO, the click-based design stands. **T0 deliverable**: a ~100-line Swift test harness in `Scripts/library-ax-probe.swift` that dumps all AX attributes of the AXBrowser and its children to stdout, run against a live Logic Pro. Result determines T1 scope.

## 13. Follow-ups (not in scope)

- **F1**: Apple Loops browser enumeration (separate AX surface)
- **F2**: Plugin preset enumeration (Channel EQ, Alchemy, etc.)
- **F3**: `library.watch_changes` file-system watcher on `~/Library/Audio/Apple Loops/` + `/Library/Application Support/Logic/`
- **F4**: Fuzzy path matching (`"warm viol"` → `"Orchestral/Strings/Warm Violins"`)

---
