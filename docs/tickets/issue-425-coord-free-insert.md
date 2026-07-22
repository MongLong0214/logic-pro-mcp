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
   false`. It is a **reachable** coordinate-only failure fallback — tried after
   the direct and search strategies — but is **unreachable in practice for the
   Release-1 supported plugins**: Gain, Channel EQ, and Compressor
   (`insertableAllowlist`) are always found by the direct or search strategy, so
   the recursive branch is a coordinate-only safety net the supported set never
   exercises.

## Discriminator honesty

`select_trace["leaf_select_coord_free"]` is sourced from the WINNING strategy
(`SlotPopupPluginClick.coordFree`) via `leafSelectCoordFree(for:)`, not the raw
flag. A recursive (coordinate-only) win therefore reports `false` even when the
flag is on, so the receipt can never be falsely pinned to the flag value.

## Tests

`Tests/LogicProMCPTests/PluginInsertVerifiedTests.swift` covers, at the helper
level, leaf press via `kAXPress`, the discriminator's value on a coord-free
direct win, `coordFree:false` taking the coordinate path (never `AXPress`), and
fail-closed behavior when `AXPress` is neutralized.

Response-level tests drive the real `defaultInsertVerified` flow (fake AX runtime
plus a DEBUG-only coordinate-actuation seam, `forceCoordinateActuationForTests`,
so no CGEvent / physical mouse is issued) and assert the assembled response's
`select_trace["leaf_select_coord_free"]`:

- a recursive (coordinate-only) win under the flag ON reports `false` — the
  flag-vs-path divergence is exercised hermetically end to end, not merely
  structurally;
- a direct win selects the leaf via `kAXPress` under the flag ON
  (`leaf_select_coord_free == true`) and via the coordinate primitives under the
  flag OFF (`false`, with no `kAXPress` on the leaf);
- an AXPress win that times out post-commit reports an AXPress commit strategy
  (`commit_strategy`), never a physical/coordinate one.
