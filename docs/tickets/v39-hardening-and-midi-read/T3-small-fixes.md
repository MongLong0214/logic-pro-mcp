# T3: 소형 수정 팩 (PR-3)

**PRD Ref**: PRD-v39-hardening-and-midi-read > US-3
**Priority**: P2
**Size**: M
**Status**: Todo
**Depends On**: None (머지 순서상 T2 이후)
**Branch**: feat/v39-small-fixes

---

## 1. Objective
MIDIPortManager cross-mode 캐시 버그 수정, `transport.toggle_autopunch` 신규(AX 버튼, State A), `track.set_automation` 문서화.

## 2. Acceptance Criteria
- [ ] AC-1: MIDIPortManager — 같은 name·같은 mode 요청은 기존 재사용 유지(MCU restart 의존: LogicProServer.swift:1008-1018), 같은 name·다른 mode는 `MIDIPortError.modeConflict`(신규 case) throw. 포트 저장 구조에 mode 표식 추가
- [ ] AC-2: `logic_transport.toggle_autopunch` — TransportDispatcher 커맨드 + RoutingTable `transport.toggle_autopunch`만(→ [.accessibility]) — set_autopunch 등 추가 라우트 금지(independent review#5, 기존 toggle_* 패턴 준수). AX 경로: 컨트롤바 Autopunch 버튼을 locale-agnostic label(기존 AXLocalePolicy/LabelSet 패턴, 최소 영어 토큰 + 확장 여지)로 탐색 → AXPress → 버튼 상태 readback으로 State A / 요청과 불일치 시 State B / 미발견 시 State C `element_not_found`(기존 FailureError 재사용 — 동일 의미 신규 코드 금지) + remediation 힌트
- [ ] AC-3: `track.set_automation`을 docs/API.md tracks 커맨드 목록에 State B(MCU, readback 불가) 시맨틱스와 함께 등재
- [ ] AC-4: help 텍스트(SystemDispatcher)/routing audit invariant/surface census 테스트가 신규 커맨드와 정합 (기존 카운트 고정 테스트 갱신 포함)

## 3. TDD Spec (Red Phase)

| # | Test Name | Type | Expected (Red) |
|---|-----------|------|----------------|
| 1 | `sendOnly_then_bidirectional_same_name_throws_modeConflict` | Unit | FAIL (현재 재사용됨) |
| 2 | `bidirectional_then_sendOnly_same_name_throws_modeConflict` | Unit | FAIL |
| 3 | `same_name_same_mode_reuse_preserved_across_restart` | Unit | 현재 PASS — 회귀 가드로 유지 |
| 4 | `toggle_autopunch_returns_stateA_on_verified_button_toggle` | Unit(mock AX) | FAIL (커맨드 부재) |
| 5 | `toggle_autopunch_returns_stateC_when_button_not_found` | Unit(mock AX) | FAIL |
| 6 | `transport_help_and_routing_include_autopunch` | Invariant | FAIL |

### Test File Location
- `Tests/LogicProMCPTests/MIDIPortTests.swift` (확장), `TransportDispatcher`/routing invariant 기존 테스트 파일 확장

### 주의
- dead-#expect 금지. AX mock은 기존 AccessibilityChannel 테스트 더블 패턴 재사용
- 버튼 label 토큰은 diacritic-sensitive 규칙 준수 (AXLocalePolicy 관례)

## 4. Implementation Guide

| File | Change |
|------|--------|
| Sources/LogicProMCP/MIDI/MIDIPortManager.swift | mode 표식 + conflict |
| Sources/LogicProMCP/Dispatchers/TransportDispatcher.swift | 커맨드 추가 |
| Sources/LogicProMCP/Channels/RoutingTable.swift + AccessibilityChannel+Transport.swift | 라우트 + AX 구현 |
| docs/API.md | autopunch + set_automation 등재 |
| Tests/… | 위 테스트 + census/invariant 갱신 |

검증: `swift test --no-parallel`.

## 5. Edge Cases
- EC-1(=E10): 컨트롤바 커스터마이즈로 버튼 숨김 → State C + 힌트
- EC-2: Logic 미실행/창 없음 → 기존 transport 계열 선행 가드 재사용

## 6. Review Checklist
- [ ] Red FAILED → Green PASSED → Refactor 유지
- [ ] MCU restart 회귀 테스트 PASS 유지
- [ ] AC 전부 / 기존 테스트 무파손
