# Branch Coverage Ownership Matrix

Maps each production branch to the test ticket that owns it. Prevents T8/T9/T10 from duplicating effort and gives session-resume a clear done-signal target.

## LibraryAccessor.swift

| Production Symbol | Branch / Path | Owner Ticket |
|-------------------|---------------|--------------|
| `LibraryNode` / `LibraryRoot` / `LibraryNodeKind` | Codable round-trip | T1 |
| `enumerate()` (legacy shallow) | click-free path | T8 |
| `enumerateAll()` (legacy depth-1) | click-through top-level | T8 |
| `enumerateTree` | happy-path | T2 |
| `enumerateTree` | maxDepth truncation | T2 |
| `enumerateTree` | duplicate-sibling `[i]` | T2 |
| `enumerateTree` | whitespace-only name skip | T2 |
| `enumerateTree` | probeTimeout | T2 |
| `enumerateTree` | visited-set cycle (E8b) | T2 |
| `enumerateTree` | Task.sleep usage | T2 |
| `enumerateTree` | panel-closed exact error | T2 |
| `enumerateTree` | E5 external mutation abort | T2 |
| `enumerateTree` | E5b self-click guard | T2 |
| `enumerateTree` | E5c focus-loss abort | T2 |
| `enumerateTree` | flatten policy | T2 |
| `parsePath` | `/` split | T3 |
| `parsePath` | `\/` escape | T3 |
| `parsePath` | trailing slash strip | T3 |
| `parsePath` | `[i]` disambig | T3 |
| `parsePath` | empty segment rejection | T3 |
| `resolvePath` | live-AX walk | T3 |
| `selectByPath` | click sequence | T3 |
| `selectByPath` | missing-intermediate abort | T3 |
| `currentPresets` | 1/2/3-column cases | T8 |
| `position(of:)` | guard, missing attr | T8 |
| `findLibraryBrowser` | Korean/English/fallback | T8 |
| `productionMouseClick` | source nil / success | T8 |
| `detectSelectedText` | always-nil contract | T8 |
| `flatten(_ root)` | depth-1 / depth-3 cases | T8 |
| `as?` guards on AXValue | LibraryAccessor.swift:~250 | T5 (E19 fix) |

## AccessibilityChannel.swift

| Symbol | Branch | Owner Ticket |
|--------|--------|--------------|
| `scanLibraryAll` | happy path | T4 |
| `scanLibraryAll` | panel-closed error | T4 |
| `scanLibraryAll` | E15 concurrent lock | T4 |
| `scanLibraryAll` | Tier-A cache hit | T4 |
| `scanLibraryAll` | Tier-A cache miss | T4 |
| `scanLibraryAll` | defer clears flag on error | T4 |
| `scanLibraryAll` | Task.sleep, no actor block | T4 |
| `scanLibraryAll` | JSON structural fields | T4 |
| `scanLibraryAll` | AC-1.6 write success | T4 |
| `scanLibraryAll` | E17 write failure tolerated | T4 |
| `scanLibraryAll` | `lastScan` cached in actor | T4 |
| `setTrackInstrument` | index absent legacy | T5 |
| `setTrackInstrument` | index+posValue CGEvent | T5 / T9 |
| `setTrackInstrument` | index+posValue nil fallback | T5 / T9 |
| `setTrackInstrument` | header not found | T5 |
| `setTrackInstrument` | path mode | T5 |
| `setTrackInstrument` | path wins over legacy | T5 |
| `setTrackInstrument` | missing both → error | T5 |
| `setTrackInstrument` | path resolves folder → error | T5 |
| `setTrackInstrument` | category/preset lookup fail | T5 |
| `setTrackInstrument` | AC-3.2 off-screen → error | T6 |
| `setTrackInstrument` | E19 as? guard nil-safe | T5 |
| `setTrackInstrument` | E10b post-event denied | T5 |
| `setTrackInstrument` | AC-2.3 legacy response JSON | T9 |
| `setTrackInstrument` | post-event probe runs once | T9 |
| `resolveLibraryPath` (new, T7) | cache hit leaf | T7 |
| `resolveLibraryPath` | cache hit folder with children | T7 |
| `resolveLibraryPath` | cache miss `lastScan == nil` | T7 |
| `resolveLibraryPath` | zero clicks recorded | T7 |
| `resolveLibraryPath` | empty path | T7 |
| `resolveLibraryPath` | disambiguated `[i]` from cache | T7 |
| `execute` case `library.scan_all` async | actor-step atomicity | T4 |
| `execute` case `library.resolve_path` | wiring | T7 |
| `execute` case `track.set_instrument` path param | wiring | T5 |

## Edge-case matrix (PRD §5 → T10 or owner)

| Edge | Owner | Notes |
|------|-------|-------|
| E1 | T10 | Panel closed |
| E2 | T10 | 0 presets in category |
| E3 | T10 + T3 | Duplicate siblings |
| E4 | T10 + T3 | `/` in preset name |
| E5 | T10 + T2 | External AX mutation |
| E5b | T10 + T2 | Scanner self-click |
| E5c | T10 + T2 | Focus loss |
| E6 | T10 | Unicode/RTL |
| E7 | T10 + T2 | Probe timeout |
| E8 | T10 + T2 | Depth cap |
| E8b | T10 + T2 | Cycle detection |
| E9 | T10 | Logic not running |
| E10 | T10 | No Accessibility permission |
| E10b | T10 + T5 | No Post-Event permission |
| E11 | T10 + T5 | Both path + legacy |
| E12 | T10 + T5 | Neither path nor legacy |
| E13 | T10 + T6 | Off-screen track |
| E14 | T10 | 0 Sound Library installed |
| E15 | T10 + T4 | Concurrent scan |
| E16 | T10 | AX error code wrap |
| E17 | T10 + T4 | Cache write failure |
| E18 | T10 | Logic window missing |
| E19 | T10 + T5 | force-unwrap guard |
| E20 | T10 + T3 | Empty path segment |
| E21 | T10 | Track index drift |
| E22 | T10 | Multiple Library panels |

Rule: a branch may appear under multiple owner columns; the **primary owner** is the first listed. T10 holds a canonical E-case test; the primary owner holds the production branch test. When coverage is measured, any uncovered branch here is a T-owner responsibility to close.
