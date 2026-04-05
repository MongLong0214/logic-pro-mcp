# T10: 통합 테스트 + 설치 스크립트 + 빌드 검증

**PRD Ref**: PRD-logic-pro-mcp-v2 > §8, §9, §4.10 Phase 6
**Priority**: P1 (High)
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T5, T6, T7, T8, T9

---

## 1. Objective
전체 통합 테스트 (MCU loopback, ChannelRouter→Channel 경로, edge cases). install.sh 업데이트 + uninstall.sh 생성. 빌드 3종 검증.

## 2. Acceptance Criteria
- [ ] AC-1: MCU loopback 통합 테스트 — 명령 전송 → 피드백 수신 → StateCache 갱신 경로
- [ ] AC-2: ChannelRouter 통합 — Dispatcher → Router → Channel → 결과 경로
- [ ] AC-3: Edge case 테스트: E1-E15 중 자동화 가능한 것 (E1,E2,E3,E6,E9,E14)
- [ ] AC-4: Scripts/install.sh 업데이트 — MCU 포트 설명 + Key Commands 설치 포함
- [ ] AC-5: Scripts/uninstall.sh 생성 — 전체 설정 롤백
- [ ] AC-6: `swift build -c release` PASS
- [ ] AC-7: `swift test` 전체 PASS + 테스트 수 50개 이상
- [ ] AC-8: 빌드 바이너리 `.build/release/LogicProMCP --check-permissions` 실행 가능
- [ ] AC-9: `swift test` coverage > 70% 측정 (lcov 또는 swift test --enable-code-coverage)
- [ ] AC-10: (수동 검증) 서버 바이너리 1시간 연속 구동 crash 0회 확인 (PRD G7 24h의 축소 검증. 24h 풀 soak은 릴리스 전 수동 수행)

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testMCULoopbackFaderRoundTrip` | Integration | set_volume → feedback → state | StateCache 값 일치 |
| 2 | `testMCULoopbackButtonRoundTrip` | Integration | mute → feedback → state | mute 상태 반영 |
| 3 | `testRouterToChannelEndToEnd` | Integration | Dispatcher.handle → result | success |
| 4 | `testLogicProNotRunningGraceful` | Integration | 모든 채널 unavailable | 서버 crash 안 함 |
| 5 | `testMCUPortCreationFailure` | Unit | 포트 생성 실패 mock | degraded mode |
| 6 | `testKeyCommandFallbackToCGEvent` | Integration | KeyCmd unavailable | CGEvent 시도 |
| 7 | `testConcurrentMCUCommands` | Integration | 10개 동시 명령 | 순차 처리, crash 없음 |
| 8 | `testDuplicatePortName` | Unit | 동일 포트 2회 | 재사용 |
| 9 | `testLogicProCrashDetection` | Integration | 실행 중→미실행 전환 | 채널 unavailable + 복구 |
| 10 | `testDegradedModeNoAXPermission` | Integration | AX 권한 없음 | CGEvent/AX unavailable, 나머지 정상 |
| 11 | `testDegradedModeNoAutomationPermission` | Integration | Automation 권한 없음 | AS unavailable |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/IntegrationTests.swift`
- `Tests/LogicProMCPTests/EdgeCaseTests.swift`

### 3.3 Mock/Setup Required
- MockMIDITransport: loopback (send → immediately receive)
- MockChannel: unavailable 상태 제어

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Tests/LogicProMCPTests/IntegrationTests.swift` | Create | 통합 테스트 |
| `Tests/LogicProMCPTests/EdgeCaseTests.swift` | Create | 엣지 케이스 |
| `Scripts/install.sh` | Modify | MCU + KeyCmd 설치 포함 |
| `Scripts/uninstall.sh` | Create | 전체 롤백 |

### 4.2 Implementation Steps (Green Phase)
1. MockMIDITransport 구현 (loopback)
2. 통합 테스트 작성 → Red → Green
3. Edge case 테스트 작성 → Red → Green
4. install.sh 업데이트
5. uninstall.sh 생성
6. 빌드 3종 검증: build + test + binary 실행

## 5. Edge Cases
- 전체 E1-E15 커버리지 확인

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] 테스트 50개+ PASS
- [ ] swift build -c release PASS
- [ ] install.sh / uninstall.sh 동작 확인 (수동)
