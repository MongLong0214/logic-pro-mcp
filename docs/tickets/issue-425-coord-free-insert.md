# #425 — Coordinate-free plugin-insert (Option B)

Status: leaf selection coordinate-free by DEFAULT; slot-open and the recursive
category-hover fallback remain coordinate by **governed waiver**.

## Decision (CEO-ratified Option B)

The plugin-insert leaf SELECTION is coordinate-free by default: it reads the
plugin's format submenu as an AX child and `AXPress`es the preferred-format leaf
(`pressPopupPluginLeaf`), with no `moveElementCenter`/`clickElementCenter`. The
`FeatureFlags.insertCoordFree` flag is retained as a **kill-switch** —
`LOGIC_MCP_INSERT_COORD_FREE=0` rolls back to the legacy coordinate leaf click.

`clickPopupPluginLeaf` takes an explicit `coordFree` argument (not a direct flag
read) so the two supported paths (direct / search) honor the flag while the
recursive fallback can force the coordinate path.

## Governed coordinate waivers (live-probed, documented)

1. **Slot-open stays a coordinate click.** Opening a slot's empty picker is a
   coordinate click on the slot element (`liveExactSlotPopupInsert`). Coord-free
   alternatives were live-probed and rejected:
   - `AXPress` on the empty-slot element is a **no-op** — the picker never opens.
   - `AXShowMenu` opens the picker into an **NSMenu tracking loop that wedges
     Logic** (AX calls block).

2. **Recursive category-hover fallback stays coordinate.** The recursive
   discovery path (`clickPopupExactLeafRecursively`) hovers categories with
   `moveElementCenter` and always selects the matched leaf with `coordFree:
   false`. It is **unreachable for the Release-1 supported plugins** — Gain,
   Channel EQ, and Compressor (`insertableAllowlist`) are always found by the
   direct or search strategy, so the recursive branch is a documented
   coordinate-fallback only.

## Discriminator honesty

`select_trace["leaf_select_coord_free"]` is sourced from the WINNING strategy
(`SlotPopupPluginClick.coordFree`), not the raw flag. A recursive
(coordinate-only) win therefore reports `false` even when the flag is on, so the
receipt can never be falsely pinned to the flag value.

## Tests

`Tests/LogicProMCPTests/PluginInsertVerifiedTests.swift` (`#425 (Option B)`
section) covers the four contract points: leaf press via `kAXPress`, the
discriminator's true value on a coord-free direct win, `coordFree:false` taking
the coordinate path (never `AXPress`), and fail-closed behavior when `AXPress`
is neutralized. A winning recursive path cannot be exercised hermetically (it
would require real on-screen geometry and post a CGEvent); that case is noted in
the test file and verified structurally.
