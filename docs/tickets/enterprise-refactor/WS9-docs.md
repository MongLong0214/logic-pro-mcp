# WS9: User-facing docs — align every md with the shipped code (PHASE 3)

**PRD**: G5, §3.2 WS9
**Priority**: P2 | **Size**: M | **Risk**: L
**Owns (EXCLUSIVE)**: `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/{API,SETUP,TROUBLESHOOTING}.md`, `docs/media/README.md`. Runs after Phase-1+2 so counts/behaviors are final.
**Depends on**: WS1-8 merged (needs the final test count, final behavior, final version).

## 1. Objective
Bring every user-facing doc into exact agreement with the shipped v3.8.0 code — fix the audit-found staleness and document this sweep's one observable change + the security posture.

## 2. Acceptance Criteria
- AC1 [audit Docs P2 #1]: Remove mixer "send" = MCU write claims — README:91, docs/TROUBLESHOOTING.md:100. Reality: `logic_mixer.set_send` is NOT exposed (State C command_not_exposed); only `set_master_volume` is live MCU. Align with API.md:84/152.
- AC2 [audit Docs P2 #2]: CONTRIBUTING.md:118 channel table "MCU | Mixer writes (fader/pan/send)" → fader/pan route to `[.accessibility]` (post-#83); correct it.
- AC3 [audit Docs P2 #3]: Test counts — README:17/60/233 (1933) and CONTRIBUTING:55/98/161 (1846) are stale AND mutually inconsistent. Re-count via `swift test --no-parallel` (post-WS8) and sync ALL sites — or stop pinning an exact number (prefer a single source or "1900+"). E2E: README:60/238 "352/352" → current strict live count (369/370 per #234, re-confirm post-integration).
- AC4 [G6 exception]: Document the `logic://tracks` honesty correction in CHANGELOG (v3.8.0) + docs/API.md — volume/pan/automationMode now report REAL track-header values (previously fabricated 0.0/0.0/.off); keys/types unchanged (value-only). Note sampleRate still project-fabricated at track layer (documented limitation).
- AC5: SECURITY.md:99 "v3.7.0" anchor → v3.8.0 (semantics unchanged, version refresh). Add the M3 notarization posture (per Phase-E decision): either "releases are notarized" or "only out-of-band-pinned install (LOGIC_PRO_MCP_SHA256+TEAM_ID) is enterprise-grade; ADHOC gives integrity not authenticity."
- AC5b [G6-(a), boomer ticket-R2 #1]: Document the **permission-probe tri-state honesty correction** (WS5) in BOTH `CHANGELOG` (Fixed) AND `docs/TROUBLESHOOTING.md` + `SECURITY.md`: `--check-permissions` / `logic_system health` / doctor no longer report a false "Automation NOT GRANTED" when the probe itself times out or fails to spawn — they now report the honest `notVerifiable` tri-state (infra-failure ≠ denial). TROUBLESHOOTING gets a note on interpreting `notVerifiable` vs `notGranted`; SECURITY notes the fail-closed-vs-honest distinction. This is the 2nd documented observable correction alongside logic://tracks (AC4).
- AC6: **CHANGELOG v3.8.0 entry** — comprehensive, Keep-a-Changelog style: Fixed (SIGPIPE, MCU race, tri-state, extractTrackState honesty, AXHelpers guard, MIDIFeedback, SMFWriter denominator, security M1/M2, release Formula-sha, doc staleness); Changed (internal God-object splits, dead-assertion sweep, dedup — note "no public surface change"); Security (M1 publish-mcp injection, M2 /private install bypass, L1/L2). Reference merged #234.
- AC7: Every documented tool/param/resource/template/version matches code (serverVersion 3.8.0; 10 tools/18 resources/11 templates — confirm unchanged). No remaining stale number.

## 3. Verification
Grep each doc for version strings, test counts, E2E counts, channel-routing claims, and the mixer "send" wording; cross-check each against the actual code/`swift test` output. A reviewer (guardian or boomer) diffs docs vs code claims.

## 4. Constraints
- Docs-only; no code. Do NOT invent capabilities — document what ships.
- Version bump to 3.8.0 in ServerConfig.swift is a Phase-E (release-prepare) step, NOT WS9 — but WS9's CHANGELOG/README must reflect 3.8.0.

## 5. Review Checklist
- [ ] mixer "send"/fader-pan channel corrected (README/TROUBLESHOOTING/CONTRIBUTING)
- [ ] test + E2E counts re-counted and synced across all sites
- [ ] logic://tracks honesty correction documented (CHANGELOG + API.md)
- [ ] SECURITY.md version + notarization posture
- [ ] permission tri-state correction documented in CHANGELOG + TROUBLESHOOTING + SECURITY (AC5b)
- [ ] CHANGELOG v3.8.0 comprehensive; every number matches code
