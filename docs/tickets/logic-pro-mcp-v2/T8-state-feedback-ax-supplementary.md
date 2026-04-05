# T8: StatePoller → AX Supplementary Poller + Resource 응답 스키마

**PRD Ref**: PRD-logic-pro-mcp-v2 > §4.8, §4.3.3
**Priority**: P1 (High)
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T4, T7

---

## 1. Objective
StatePoller를 MCU 피드백 기반 hybrid 모드로 전환. AX supplementary polling(5초)은 Region/Marker/ProjectInfo만. Resource 응답을 §4.3.3 스키마에 맞게 수정.

## 2. Acceptance Criteria
- [ ] AC-1: StatePoller rename → AXSupplementaryPoller, transport/tracks polling 제거 (MCU 대체)
- [ ] AC-2: AX polling 간격 5초, Region/Marker/ProjectInfo만
- [ ] AC-3: `logic://tracks` 응답에 automationMode 필드 포함 (§4.3.3)
- [ ] AC-4: `logic://mixer` 응답에 mcu_connected 메타 포함 (§4.3.3)
- [ ] AC-5: `logic://system/health` 응답이 §4.3.2 JSON 스키마와 일치

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testTracksResponseIncludesAutomation` | Unit | tracks 리소스 응답 | automationMode 필드 존재 |
| 2 | `testMixerResponseIncludesMCUStatus` | Unit | mixer 리소스 응답 | mcu_connected 필드 존재 |
| 3 | `testHealthResponseFullSchema` | Unit | health 응답 | mcu/channels/cache/permissions/process 섹션 |
| 4 | `testHealthResponseMCUFields` | Unit | health mcu 섹션 | connected/registered/lastFeedbackAt/stale |
| 5 | `testHealthResponseProcessFields` | Unit | health process 섹션 | memory_mb/cpu_percent/uptime_sec |
| 6 | `testMixerResponseIncludesPluginParams` | Unit | mixer 응답 plugins[] | plugins 필드 존재 |
| 7 | `testHealthResponseMCUDisconnected` | Unit | MCU 미연결 시 health | connected=false |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/ResourceSchemaTests.swift`

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/State/StatePoller.swift` | Modify | Rename + 축소 (AX supplementary만) |
| `Sources/LogicProMCP/Resources/ResourceHandlers.swift` | Modify | tracks/mixer/health 응답 스키마 변경 |
| `Sources/LogicProMCP/State/StateModels.swift` | Modify | TrackState.automationMode 이미 T4에서 추가 |
| `Sources/LogicProMCP/State/StateCache.swift` | Modify | snapshot()에 MCU 연결 상태 포함 |
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Modify | StatePoller→AXSupplementaryPoller rename 반영 |

### 4.2 Implementation Steps (Green Phase)
1. StatePoller → AXSupplementaryPoller rename
2. pollLoop()에서 transport/tracks polling 제거
3. AX polling 간격 5초로 변경
4. ResourceHandlers: tracks 응답에 automationMode
5. ResourceHandlers: mixer 응답에 mcu_connected wrapper
6. ResourceHandlers.readSystemHealth → **SystemDispatcher.handle("health")에 위임** (단일 canonical source). tool health와 resource health가 동일 코드 경로를 공유하여 drift 방지
7. StateCache.snapshot()에 MCU 연결 정보 포함
8. StatePoller.pollLoop()를 5초 고정 간격 단순 루프로 교체. PollMode/PollInterval/transportCounter 전부 제거

## 5. Edge Cases
- EC-1: AX 권한 없음 → supplementary polling 비활성, MCU 피드백만 (E11)

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] §4.3.2, §4.3.3 스키마 일치
