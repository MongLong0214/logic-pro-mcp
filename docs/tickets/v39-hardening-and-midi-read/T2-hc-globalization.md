# T2: HC 전역화 마감 (PR-2)

**PRD Ref**: PRD-v39-hardening-and-midi-read > US-2
**Priority**: P1
**Size**: L
**Status**: Todo
**Depends On**: None (머지 순서상 T1 이후)
**Branch**: feat/v39-hc-globalization

---

## 1. Objective
logic_midi mutating 커맨드의 평문 성공 응답을 전부 HC State B envelope로 통일하고, mutating route 전수가 HC JSON을 반환함을 ratchet invariant 테스트로 영구 고정한다. **BREAKING** (응답 shape).

## 2. Acceptance Criteria
- [ ] AC-1: 대상 전수 확정 — 권위 소스는 `LogicProServer.mutatingCommandsByTool["logic_midi"]` (independent review#4: RoutingTable은 `midi.*`와 `mmc.*`로 갈라져 있음). 각 커맨드의 dispatcher→route 매핑을 따라 RoutingTable 목적지(`midi.*`/`mmc.*`/keycmd)를 테스트로 assert. 제외: list_ports(read-only), import_file(기존 HC 유지). **carve-out (independent review#2)**: `mmc_locate(bar)`는 `transport.goto_position` 경유 + transport readback으로 State A/B를 반환하는 기존 검증 경로(Issue108Tests 고정) — 절대 State B 강등 금지. 변환 대상은 send-only 성공 경로만(time-based mmc.locate raw, mmc_play/stop/record, send_* 계열)
- [ ] AC-2: CoreMIDIChannel의 모든 성공 반환(`.success("MMC play sent")` 등 ~12곳)이 HC State B JSON(`success:true, verified:false, reason:"send_only_no_readback"` 계열 — 기존 HonestContract encode API 사용, 새 reason 코드 필요 시 기존 enum 확장)으로 교체. 기존 메시지/바이트 수는 extras로 보존
- [ ] AC-3: 전역 HC invariant 테스트 — RoutingTable mutating op 전수 순회, 채널 mock으로 실행한 응답이 JSON object + `success`/`verified`/`state` 키 보유 검증. 라이브 전용 op는 명시 allowlist skip + **allowlist 크기 상한 ratchet 테스트**(상한 = 현재 크기, 증가 시 컴파일/테스트 fail)
- [ ] AC-4: `Scripts/live-e2e-test.py`의 logic_midi 관련 assertion을 새 State B shape 기준으로 갱신 (구 평문 핀 제거)
- [ ] AC-5: CHANGELOG [Unreleased]에 BREAKING 명시 + docs/API.md logic_midi 응답 예시 갱신

## 3. TDD Spec (Red Phase)

| # | Test Name | Type | Expected (Red) |
|---|-----------|------|----------------|
| 1 | `coreMIDI_sendNote_success_returns_stateB_envelope` | Unit | FAIL (현재 평문) — mock MIDI engine 사용 |
| 2 | (커맨드별 반복 — sysex/mmc/cc/pitch_bend/aftertouch/chord/program_change/play_sequence 등 전 대상) | Unit | FAIL |
| 3 | `all_mutating_routes_return_hc_json` | Invariant | FAIL (CoreMIDI 평문 잔존 동안) |
| 4 | `hc_invariant_allowlist_ratchet` | Invariant | 구현 후 상한 고정 |
| 5 | `stateB_extras_preserve_legacy_info` | Unit | FAIL — bytes 수 등 extras 검증 |

### Test File Location
- `Tests/LogicProMCPTests/CoreMIDIChannelTests.swift` 계열(기존 파일 확장) + `Tests/LogicProMCPTests/HCGlobalInvariantTests.swift` (신규)

### 주의
- 기존 State C(inactive/failure) 래핑 코드(`encodeStateC`, CoreMIDIChannel.swift:510-529)와 동일한 HonestContract API 사용 — 새 encoding 경로 발명 금지
- dead-#expect 금지
- MCUChannel/AX 채널의 기존 HC 응답은 무변경 (invariant 테스트가 통과 확인만)

## 4. Implementation Guide

| File | Change |
|------|--------|
| Sources/LogicProMCP/Channels/CoreMIDIChannel.swift | 성공 반환 전부 State B |
| Sources/LogicProMCP/Utilities/HonestContract.swift | (필요 시) reason 코드 추가만 |
| Tests/… | 위 테스트 |
| Scripts/live-e2e-test.py | shape 갱신 |
| CHANGELOG.md, docs/API.md | BREAKING + 예시 |

검증: `swift test --no-parallel` + `python3 -m py_compile Scripts/live-e2e-test.py`.

## 5. Edge Cases
- EC-1: `mmc_locate(bar)` readback 경로 무변경 — Issue108Tests가 회귀 가드 (time-based raw locate만 State B 전환)
- EC-2: create_virtual_port는 포트 정보 반환 — State B extras에 포트 식별 정보 보존

## 6. Review Checklist
- [ ] Red FAILED → Green PASSED → Refactor 유지
- [ ] invariant allowlist에 신규 진입 없음 (CoreMIDI 전부 해소)
- [ ] AC 전부 / 기존 테스트 무파손 / BREAKING 문서화
