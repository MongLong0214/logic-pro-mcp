# T0 Spike Result — AX Passive-Attribute Probe

**Date**: 2026-04-12
**Probe script**: `Scripts/library-ax-probe.swift`
**Target**: Logic Pro 12.x with Library panel open (⌘L)

---

## Verdict

**GO-CLICK-BASED** with **design-simplification note**.

## Evidence

### AXBrowser exposes 19 attributes; key ones:
```
AXRole              = AXBrowser
AXDescription       = 라이브러리 (or "Library" in English locale)
AXColumns           = Array[2]         ← only 2 columns
AXVisibleColumns    = Array[2]         ← same 2 columns
AXColumnTitles      = <nil>
AXChildren          = Array[1]         ← single AXScrollArea
```

### Column structure (from `AXColumns`)
```
col[0] AXScrollArea → AXContents[0] = AXList (children=13) — categories
        each child: AXStaticText, value="Bass"|"Orchestral"|...
        AXDisclosing=false, AXDisclosed=false, AXDisclosureLevel=-1

col[1] AXScrollArea → AXContents[0] = AXList (children=12) — presets of currently-selected category
        each child: AXStaticText, value="Bright Suitcase"|...
        AXDisclosing=false, AXDisclosed=false, AXDisclosureLevel=-1
```

### No hierarchy indicators
- No `AXRows` on columns (AXList, not AXOutline/AXTable)
- No disclosure triangles (`AXDisclosing == false` on every static text)
- `AXColumns.count` is **fixed at 2**, does not grow when user drills further
- `AXColumnTitles` is nil — no hidden row metadata

### Implication
Logic Pro 12's built-in Library (as installed on this machine) is structurally a **2-level flat master-detail browser**:
- Level 1: 13 categories
- Level 2: N presets per category

There are **no subfolders**. The 259-preset result from the pre-spike live scan is **100 %** of installed Library content. The user's low counts for Orchestral (2) / Guitar (3) / Bass (4) reflect what the user has **downloaded**, not a scanner limitation.

### Does a passive attribute expose the full tree?
**No.** `AXColumns[1]` (the preset column) only contains presets for whichever category is currently selected. Switching categories still requires a click + settle. The passive attribute exists but only exposes *current visible state*, which is what the existing `enumerate()` already reads.

---

## Recommendation

**Proceed with PRD v0.3 ticket plan (T1-T11) as approved.** Do NOT Phase 3-역행.

Rationale:
1. The recursive `enumerateTree()` in T2 handles depth=1 correctly as a trivial case (loop over categories, click each, read column 2, no deeper recursion). Running cost is identical to the existing `enumerateAll()` for flat libraries.
2. All other PRD deliverables (AC-1.6 JSON persistence, AC-1.7 Tier-A selection restore, AC-1.8 Task.sleep, AC-2.1-2.8 path mode, AC-3.1-3.3 track selection, E10b Post-Event probe, E15 concurrent lock, E19 force-unwrap fix, §8 comprehensive tests) remain valuable regardless of depth.
3. **Defensive over-design is acceptable** for this surface — if Apple extends Logic 13 with subfolder patches, our code is ready without re-architecting.
4. Ticket scope edits would burn more time than the ~10% implementation savings.

### Minor scope adjustments (apply inline, do not re-loop tickets)
- **T2** maxDepth default stays at 12 but in practice depth ≤ 1 here; comment in code.
- **T2** visited-set still implemented — cost is zero for flat trees.
- **T3** `resolvePath` path parser handles `"A/B"` only in practice; deeper paths return `exists:false` rather than click through.
- **AC-1.5 performance re-basis** — for 13 categories × ~20 presets avg, expected wall-clock with `settleDelayMs=500` is `13 × 500 ms + 259 × 15 ms = 10.4 s` (matches PRD §7 current-user formula — already aligned).

### Follow-up (out of scope for this PRD)
- **F-series F6**: If a future Logic Pro version adds hierarchical Library, the recursive walker auto-handles it; no code change beyond raising `maxDepth` default if > 12.
- **F-series F2 (plugin presets)** remains the next logical surface; plugin UIs DO have deeper hierarchies (Alchemy, ES2 browser trees).

---

## STATUS.md update

T0 = **Done (GO-CLICK-BASED)**. Proceeding to T1.
