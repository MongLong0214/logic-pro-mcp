# Issue #14 Ticket Board: Verified Stock Plugin Intelligence

**Issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/14
**PRD**: `docs/prd/PRD-verified-stock-plugin-intelligence.md`
**Status**: Done

## Tickets

- [x] `I14-T1` Schema and validator
  - Define truth labels, provenance, plugin entries, insert paths, slot support, parameter metadata, and catalog snapshot.
  - Validator rejects duplicate IDs, missing verified provenance, and verified parameters without readback evidence.

- [x] `I14-T2` Deterministic catalog and census overlay
  - Seed conservative Logic stock plugin entries.
  - Overlay current-machine census data without promoting static guesses to verified.
  - Include at least one unavailable expected entry for client branch coverage.

- [x] `I14-T3` MCP resources
  - Register `logic://stock-plugins`, `logic://stock-plugins/{id}`, `logic://stock-plugins/search?query=`, `logic://stock-plugins/census`, and `logic://stock-plugins/capabilities`.
  - Keep resources read-only and side-effect free.

- [x] `I14-T4` Tests
  - Unit tests for validator/catalog/search.
  - Resource and server E2E tests for all surfaces.
  - Safety regression proving write-side gates are not broadened.

- [x] `I14-T5` Docs and evidence
  - Update API and troubleshooting docs.
  - Add live/deterministic verification evidence.

## Done Criteria

- All tickets complete.
- `swift build -c release` and `swift test --no-parallel` pass.
- `python3 -m py_compile Scripts/live-e2e-test.py` passes.
- Live evidence is recorded when Logic is available; otherwise the limitation is explicit and no live-verified claim is made.

## Hardening Round (2026-06-10)

Adversarial review (Codex gpt-5.5 xhigh + full-repo review cross-check) returned 3 P1 / 4 P2 findings. All addressed:

- [x] `R1` Fabricated provenance removed: blanket app-presence no longer claims `manifested`; the census now probes per-plugin factory `Plug-In Settings/<Display Name>` folders (app bundle + `/Library/Application Support/Logic`) and records the probed `source_path`. The hardcoded `unavailable` SilverVerb entry (claimed `absence_checked` without any check — the folder exists in Logic 12.2) is replaced by a real probed entry.
- [x] `R2` Every truth state is now producible and tested: census carries `verified`/`observed`/`readback_mismatch`/`unavailable` ID sets plus local manifests; overlay precedence is tested per state. Production probe alone can never claim more than `manifested` (regression-tested).
- [x] `R3` Deterministic tests pinned to `StockPluginCensus.deterministic()`; production snapshot asserted conservative on any host.
- [x] `R4` URI routing fails closed via `URLComponents` (unknown subpaths, nested segments, stray query params rejected); search query double-decode bug fixed and regression-tested.
- [x] `R5` Catalog expanded to 103 documented stock entries (effects/instruments/MIDI FX) under `logic.stock.{effect,instrument,midi_fx}.*` with honest `inferred` baselines; `known_presets` populated only from probed factory preset filenames (capped, provenance-marked). Validator extended: id format, value-range sanity, duplicate parameter IDs, preset provenance, mismatch evidence.
- [x] `R6` `safe_write_capabilities: insert_only` pinned to the live `insert_plugin` allowlist (Gain, Compressor, Channel EQ) by test.
- [x] `R7` Shared resource JSON helpers moved to `ResourceJSONHelpers.swift` so #14/#15 branches no longer collide on duplicated private helpers.

Release identity note: `serverVersion` stays `3.4.6` on this branch by design — packaging surfaces (manifest/Formula/install.sh) pin the published v3.4.6 artifacts and must not drift mid-branch. Merging this PR requires the next release to ship as `v3.5.0` (new public resources = minor bump); do not rebuild/redistribute as `3.4.6`.

## Verification

See `docs/tickets/issue14-verified-stock-plugin-intelligence/VERIFICATION-2026-06-09.md` and `docs/tickets/issue14-verified-stock-plugin-intelligence/VERIFICATION-2026-06-10.md` (hardening round).

Final production-readiness pass (2026-06-10):

- Resource/template catalog assertions were hardened to require the #14 surface as a subset rather than freezing exact counts, and `logic_system help` now derives catalog counts from `ResourceProvider` so later public resources cannot stale the banner.
- `swift test --no-parallel` — 1232 tests passed.
- `swift build -c release` — passed.
- `PYTHONPYCACHEPREFIX=/private/tmp/lpm-pycache-issue14 python3 -m py_compile Scripts/live-e2e-test.py` — passed.
- `git diff --check origin/main` — passed.
- `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh` — 283/283 passed.
