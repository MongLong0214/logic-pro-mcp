# T0: AX Probe Spike — Plugin Setting Menu

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §12 OQ-1 (8 questions)
**Priority**: P0 (Blocker — all subsequent tickets depend on T0 result)
**Size**: M
**Status**: Todo
**Depends On**: None

---

## 1. Objective
Validate the 8 T0 questions from PRD §12 OQ-1 via a live-probe Swift script. Determine whether `AXPress` on the Setting-menu `AXMenuButton` / `AXMenuItem` works on Logic Pro 12 plugin windows, or if CGEvent fallback is required. Deliver `docs/spikes/F2-T0-plugin-menu-probe-result.md` with a GO/NO-GO-CGEVENT verdict.

## 2. Acceptance Criteria
- [ ] **AC-1**: `Scripts/plugin-menu-ax-probe.swift` exists, runs as `swift Scripts/plugin-menu-ax-probe.swift` with Logic Pro open and ES2 loaded on the first instrument track.
- [ ] **AC-2**: Probe script answers each of the 8 OQ-1 questions and dumps raw output to stdout; each answer is captured in `docs/spikes/F2-T0-plugin-menu-probe-result.md`.
- [ ] **AC-3**: Verdict section in the result doc: `GO-AXPRESS` | `GO-CGEVENT` | `MIXED` with rationale.
- [ ] **AC-4**: Result doc captures AXIdentifier / AXDescription / AXTitle formats for at least ES2 (validation path for T4). Alchemy + DMD deferred to live-run but not blocking (can be "UNAVAILABLE — no live Alchemy" in spike; noted in doc).
- [ ] **AC-5**: Result doc records empirical `submenuOpenDelayMs` floor (shortest observed that still reliably populates the submenu on ES2).

## 3. TDD Spec
Spike tickets do NOT have traditional unit tests (they probe live external state). Output correctness is validated by manual review of the result doc.

### 3.1 Test plan
- Run script in empty state (Logic not running) → expect clear "Logic Pro not running" error, no crash.
- Run script with Logic running but no plugin window → expect "No plugin window found" error, no crash.
- Run script with Logic + ES2 open → expect structured attribute dump and probe answers.

### 3.2 Files to Create
| File | Type | Description |
|------|------|-------------|
| `Scripts/plugin-menu-ax-probe.swift` | Create | Standalone Swift script; mirrors `Scripts/library-ax-probe.swift` structure. |
| `docs/spikes/F2-T0-plugin-menu-probe-result.md` | Create | Findings + GO/NO-GO verdict. |

## 4. Implementation Guide

### 4.1 Probe script structure (mirrors `library-ax-probe.swift`):
1. Attach to Logic Pro via `AXUIElementCreateApplication(pid)`.
2. Find frontmost plugin window: iterate `kAXChildrenAttribute` of app root, filter `AXWindow` with AXSubrole matching `AXStandardWindow` or AXDescription containing plugin name keywords.
3. For the located window:
   - Dump all attribute names + values (one-level)
   - Locate the Setting dropdown via role search: `AXMenuButton` in header region (top-center of window)
   - Print `AXIdentifier` / `AXDescription` / `AXTitle` / `AXPosition` / `AXSize`
4. Attempt `AXUIElementPerformAction(dropdown, kAXPressAction as CFString)`:
   - Report success/failure code
   - Wait 300 ms; read `AXChildren` of dropdown — did an `AXMenu` appear?
5. If AXMenu appeared: for each `AXMenuItem`, print name + `kAXHasChildrenAttribute` (or proxy). Pick one submenu item; AXPress it; wait 300 ms; check if its children populated.
6. Report empirical settle delay: binary search 100/200/300/500/800 ms intervals; record fastest reliable.
7. Detect menu dismiss behaviour after leaf click: AXPress a leaf; inspect whether the menu auto-dismisses (by polling for menu presence).
8. Dump AXIdentifier of the plugin window itself (AC-5.3 dependency).

### 4.2 Result doc structure
- **Environment**: Logic Pro version, macOS version, M-series chip
- **Q1–Q8 answers** (one section each, with raw AX output snippets)
- **Verdict**: GO-AXPRESS | GO-CGEVENT | MIXED
- **Follow-ups**: deferred (e.g., "Alchemy not available in spike; retest before Phase 5 manual QA").
- **T1 implications**: list which PRD decisions are locked by this result.

## 5. Edge Cases
- EC-1 (E11c): If Automation prompt fires during AXPress, note it — this is expected first-run behavior.

## 6. Review Checklist
- [ ] Script runs without crashing across: no-Logic, no-plugin, happy-path
- [ ] 8 OQ-1 questions all answered (or marked UNAVAILABLE with reason)
- [ ] Verdict is unambiguous
- [ ] AXIdentifier/AXDescription/AXTitle format documented for ES2
- [ ] Empirical settle delay recorded
