# T6: Scripter MIDI FX 채널 + JS 템플릿

**PRD Ref**: PRD-logic-pro-mcp-v2 > US-2, §4.7
**Priority**: P2 (Medium)
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: T2

---

## 1. Objective
ScripterChannel 구현: MIDI CC 102-119 on CH 16 전송 → Logic Pro Scripter가 플러그인 파라미터 변경. JS 템플릿 파일 생성.

## 2. Acceptance Criteria
- [ ] AC-1: ScripterChannel이 Channel 프로토콜 구현
- [ ] AC-2: execute("plugin.set_param", {param: 3, value: 0.5}) → CC 104 value 64 on CH 16
- [ ] AC-3: Scripts/LogicProMCP-Scripter.js 생성 (§4.7 템플릿)
- [ ] AC-4: healthCheck → 포트 존재 시 available 반환 (Scripter 설치 여부는 프로그래밍으로 감지 불가 — MIDI 전송 가능 여부만 판단). Scripter 미설치 시 MIDI CC가 무시되지만 에러는 아님. `logic_system("health")`에 "scripter: available (installation not verifiable)" 표기

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testScripterParamToCC` | Unit | param 0 → CC 102 | CC 102 |
| 2 | `testScripterParamRange` | Unit | param 0-17 | CC 102-119 |
| 3 | `testScripterValueNormalize` | Unit | value 0.5 → MIDI | velocity 64 |
| 4 | `testScripterOutOfRange` | Unit | param 18 | error |
| 5 | `testScripterChannel16` | Unit | 모든 메시지 | MIDI channel 16 |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/ScripterChannelTests.swift`

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/ScripterChannel.swift` | Create | Scripter 채널 |
| `Scripts/LogicProMCP-Scripter.js` | Create | JS 템플릿 |
| `Tests/LogicProMCPTests/ScripterChannelTests.swift` | Create | 테스트 |
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Modify | ScripterChannel 등록 |

### 4.2 Implementation Steps (Green Phase)
1. ScripterChannel actor: param index → CC 102+index, value → 0-127
2. healthCheck: 포트 존재 여부만 (Scripter 설치 여부는 감지 불가)
3. JS 템플릿 파일 (§4.7 코드)
4. 테스트 → Red → Green

## 5. Edge Cases
- EC-1: Scripter 미설치 (E5) — MCU plugin mode fallback

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] JS 템플릿 §4.7과 일치
