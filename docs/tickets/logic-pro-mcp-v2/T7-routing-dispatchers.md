# T7: ChannelRouter 전면 재작성 + Dispatcher 업데이트

**PRD Ref**: PRD-logic-pro-mcp-v2 > §4.3, §4.3.1
**Priority**: P0 (Blocker)
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: T4, T5, T6

---

## 1. Objective
ChannelRouter 라우팅 테이블을 7채널(MCU, MIDIKeyCmds, CoreMIDI, Scripter, AppleScript, CGEvent, AX)로 전면 교체. 8 Dispatcher의 operation key 정합성 전수 수정. 신규 command 추가 (§4.3.1).

## 2. Acceptance Criteria
- [ ] AC-1: ChannelRouter에 7채널 등록 (.osc 완전 제거 확인)
- [ ] AC-2: mixer operations → MCU primary (fallback 없음)
- [ ] AC-3: edit/navigate operations → MIDIKeyCmds primary, CGEvent fallback
- [ ] AC-4: transport.set_tempo → MIDIKeyCmds primary (MCU에 없음)
- [ ] AC-5: 신규 commands 추가: set_plugin_param, step_input, toggle_step_input, set_automation
- [ ] AC-6: 기존 commands 유지: set_volume(pan -1.0~1.0), set_send(bus 파라미터명)
- [ ] AC-7: operation key 불일치 0건 (Dispatcher→Router→Channel 정합)
- [ ] AC-8: swift build + swift test PASS

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testRouterMixerGoesToMCU` | Unit | mixer.set_volume 라우팅 | MCU 채널 |
| 2 | `testRouterEditGoesToKeyCmd` | Unit | edit.undo 라우팅 | MIDIKeyCmds 채널 |
| 3 | `testRouterEditFallbackCGEvent` | Unit | KeyCmd unavailable 시 | CGEvent fallback |
| 4 | `testRouterSetTempoGoesToKeyCmd` | Unit | transport.set_tempo | MIDIKeyCmds (not MCU) |
| 5 | `testRouterMixerNoFallback` | Unit | MCU unavailable 시 mixer | error 반환 |
| 6 | `testRouterNewCommandSetPluginParam` | Unit | mixer.set_plugin_param | MCU 채널 |
| 7 | `testRouterNewCommandStepInput` | Unit | midi.step_input | CoreMIDI 채널 |
| 8 | `testRouterNewCommandSetAutomation` | Unit | track.set_automation | MCU 채널 |
| 9 | `testRouterAllOperationsHaveChannel` | Unit | 모든 operation에 채널 할당 | 미할당 0 |
| 10 | `testDispatcherSetPluginParamParams` | Unit | set_plugin_param 파라미터 전달 | track/insert/param/value |
| 11 | `testDispatcherStepInputParams` | Unit | step_input 파라미터 전달 | note/duration |
| 12 | `testDispatcherSetAutomationParams` | Unit | set_automation 파라미터 전달 | index/mode |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/ChannelRouterTests.swift`
- `Tests/LogicProMCPTests/DispatcherTests.swift`

### 3.3 Mock/Setup Required
- MockChannel: Channel 프로토콜 준수하는 mock (execute 캡처, healthCheck 결과 제어)

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Modify | 라우팅 테이블 전면 교체 |
| `Sources/LogicProMCP/Dispatchers/MixerDispatcher.swift` | Modify | set_plugin_param 추가 |
| `Sources/LogicProMCP/Dispatchers/MIDIDispatcher.swift` | Modify | step_input 추가 |
| `Sources/LogicProMCP/Dispatchers/EditDispatcher.swift` | Modify | toggle_step_input 추가 |
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Modify | set_automation 추가 |
| `Sources/LogicProMCP/Dispatchers/TransportDispatcher.swift` | Modify | set_tempo 채널 변경 |
| `Sources/LogicProMCP/Dispatchers/SystemDispatcher.swift` | Modify | health JSON 스키마 (§4.3.2) |
| `Sources/LogicProMCP/Dispatchers/NavigateDispatcher.swift` | Modify | MCU+MIDIKeyCmds 라우팅 반영 |

### 4.2 Implementation Steps (Green Phase)
1. ChannelRouter: routingTable 전면 교체 (§4.3 기준)
2. ChannelRouter: 7채널 등록 로직
3. MixerDispatcher: set_plugin_param case 추가
4. MIDIDispatcher: step_input case 추가
5. EditDispatcher: toggle_step_input case 추가
6. TrackDispatcher: set_automation case 추가
7. SystemDispatcher: health JSON 스키마 §4.3.2에 맞게 확장
8. operation key 전수 검증 (Dispatcher→Router→Channel)

## 5. Edge Cases
- EC-1: MCU 미연결 시 mixer → error (AC-1.5)
- EC-2: KeyCmd 미설치 시 edit → CGEvent fallback (E6)

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] .osc 흔적 0
- [ ] 모든 operation key 정합
- [ ] 신규 commands 동작
