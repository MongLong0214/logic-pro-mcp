# CEO correction — invalidation + exact rerun order (HEAD 8204877c)

**Recorded:** 2026-07-16  
**Binding candidate HEAD:** `8204877c2d66d11598ac5e7292d231fa42c8a8b3`  
**Sealed universal binary SHA-256 (current tree artifact):** `8c3a525a89a6bbaaff09e362ea35aae8391243d9eff1221c1161aa58257262d6`

## Invalidated (do not treat as current evidence)

| Packet / claim | Why invalidated |
|----------------|-----------------|
| CTO final review binding `cc5922e5…` dirty base + suite `eda1c7e6…` (2777) | Wrong candidate identity; superseded by committed HEAD `8204877c` |
| All live attestations with `commitSHA=cc5922e5…` (desktop-ko-retry, m4-post-release, ceo-final-*, etc.) | Not exact-head for `8204877c` |
| `exact-head-full-suite-8204877.log` / `-v2.log` as sole binders | Raw log body does **not** independently contain HEAD `8204877c` or binary digest |
| `exact-head-release-8204877.log` as sole binder | Raw log lacks HEAD + binary SHA-256 seal lines |
| Prior mutation `live/mutation/exact-head-8204877-ko` M1 | Failed: no track volume (empty project); not mutation PASS |
| Stale board STATUS/BOARD claiming cc5922e package as current | Superseded by this correction |

**Preserved only as historical archive**, not production-terminal binders.

## Exact rerun order (8204877c)

1. **Identity gate** — `git rev-parse HEAD` must equal `8204877c2d66d11598ac5e7292d231fa42c8a8b3`
2. **Full suite sealed** — `swift test --no-parallel` with identity header/footer (HEAD + binary SHA) in the **same raw log**
3. **Release/universal artifact sealed** — binary SHA-256 + HEAD stamped in raw release/identity log; binary path `./LogicProMCP`
4. **Desktop/ko mutation (mandatory)** on sealed binary:
   - mutation → independent readback → restore/compensation → restore-readback
   - fail-closed: wrong-target + unknown-command (`write_attempted=false`)
5. **`--verify-promotion`** on exact-head Desktop/ko attestation → require `promotable=true` or exact rejections
6. **Immutable evidence publish** + **CTO exact-head review** on `8204877c` only
7. **Push branch + draft PR → #367** (no merge; #286 blocked)

## Binding rules

- Filename is not identity. Raw log or attestation fields must contain HEAD and/or binary SHA.
- Product-source drift after seal invalidates suite/release/live lanes for that seal.
