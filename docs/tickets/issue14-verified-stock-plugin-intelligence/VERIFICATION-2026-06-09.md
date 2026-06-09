# Verification Evidence - Issue #14 Verified Stock Plugin Intelligence

Date: 2026-06-09 KST
Branch: `plan/14-15-prd-restart`
Scope: current working tree, Logic Pro MCP release binary, Logic Pro 12.2 host.

## Claim Boundary

The implemented #14 surface is read-only catalog intelligence. It does not broaden plugin insertion or parameter-write behavior. Catalog entries can be `manifested` from local Logic app metadata, `inferred` from static catalog knowledge, `unavailable`, `observed`, `verified`, or `readback_mismatch`; `verified` requires provenance and evidence.

`known_presets` is part of the schema, but remains empty unless preset names have provenance. Parameter metadata remains conservative and cannot be `verified` without readback evidence.

## Deterministic Gates

| Gate | Result | Evidence |
|---|---:|---|
| Format check | PASS | `git diff --check` exit 0. |
| Focused catalog/workflow tests | PASS | `swift test --filter StockPluginCatalogTests --filter WorkflowSkillCatalogTests` -> 10 tests passed. |
| Full test suite | PASS | `swift test --no-parallel` -> 1220 tests passed. |
| Release build | PASS | `swift build -c release` -> build complete. |
| Python E2E syntax | PASS | `PYTHONPYCACHEPREFIX=/private/tmp/logic-pro-mcp-pycache python3 -m py_compile Scripts/live-e2e-test.py` exit 0. |
| Coverage gate | PASS | `swift test --enable-code-coverage --no-parallel` -> 1220 tests passed; TOTAL region 73.52%, line 81.45% against CI hard gate region >=70%, line >=78%. |

## Release-Binary Read-Only Smoke

Command: release-binary MCP stdio smoke against `.build/release/LogicProMCP`.

Result:

```json
{"host_logic_version":"12.2","ok":true,"resource_count":13,"stock_catalog_source":"static_catalog+local_logic_app","stock_catalog_valid":true,"stock_census_entries_by_state":{"manifested":4,"unavailable":1},"stock_census_logic_version":"12.2","stock_gain_availability_state":"manifested","stock_gain_known_presets_count":0,"stock_insert_workflow_evidence_level":"live_verified","stock_insert_workflow_production_ready":true,"template_count":7,"workflow_count":7,"workflow_pack_valid":true}
```

`resource_count` is 13 because `logic://mcu/state` is hidden when the resource list is filtered for the current MCU state; CI accepts 13 or 14.

## Live Stock Plugin Insert Evidence

Issue #14 asks for targeted live verification around at least one safe stock plugin insert/readback path. The current branch reuses the existing repository evidence for the already-supported guarded path:

- Evidence file: `docs/tickets/mixer-verification/VERIFICATION-2026-06-09.md`
- Logic Pro version: 12.2.
- Operation: `logic_mixer insert_plugin { track: 0, slot: 6, plugin_name: "Gain", confirmed: true }`.
- Result: State A with `success:true`, `verified:true`, `verify_source:"ax_plugin_slot"`, `observed_plugin_name:"Gain"`.
- Guardrail: repeating the same insert failed closed with `slot_occupied`.

Fresh reruns on 2026-06-09 reached a valid TCC/tmux live context but the Logic GUI was stuck behind the Project Chooser modal, so current-session insert attempts failed closed with `element_not_found` / `Cannot locate visible mixer for insert_plugin`. This failure is recorded as a live precondition block, not as a product success claim.

## Acceptance Mapping

- PRD/ticket docs: `docs/prd/PRD-verified-stock-plugin-intelligence.md`, this ticket board.
- Schema: `Sources/LogicProMCP/Plugins/StockPluginCatalog.swift` includes stable IDs, display names, type/category, truth state, provenance, insert paths, slot support, `known_presets`, parameter metadata, and safe write capability labels.
- Tests: `Tests/LogicProMCPTests/StockPluginCatalogTests.swift` covers duplicate IDs, provenance, verified-parameter readback, conservative states, and MCP resources.
- Resources: `logic://stock-plugins`, `logic://stock-plugins/{id}`, `logic://stock-plugins/search?query=`, `logic://stock-plugins/census`, `logic://stock-plugins/capabilities`.
- Safety: discovery resources are read-only; existing write gates are unchanged and insert verification evidence remains L2/confirmed.
