# T4: MCU Channel + Feedback Parser + StateCache 연동

**PRD Ref**: PRD-logic-pro-mcp-v2 > US-1, US-7, §4.8, §4.9
**Priority**: P0 (Blocker)
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: T2, T3

---

## 1. Objective
MCUChannel actor 구현: Channel 프로토콜 준수, MCU 피드백 수신 → MCUFeedbackParser → StateCache 갱신, 뱅킹 트랜잭션, verify-after-write, 핸드셰이크.

## 2. Acceptance Criteria
- [ ] AC-1: MCUChannel이 Channel 프로토콜(start/stop/execute/healthCheck) 구현
- [ ] AC-2: start()에서 가상 MIDI 포트 생성 + Device Query 핸드셰이크
- [ ] AC-3: MCU 피드백(Pitch Bend, Note On/Off, LCD SysEx) → StateCache 자동 갱신
- [ ] AC-4: `execute("mixer.set_volume", params)` → MCU Pitch Bend 전송 + verify-after-write
- [ ] AC-5: 8채널 초과 뱅킹 트랜잭션 atomic (§4.9 lock + queue)
- [ ] AC-6: MCUConnectionState(isConnected, registeredAsDevice, lastFeedbackAt) 관리
- [ ] AC-7: stop()에서 포트 해제

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testMCUChannelStart` | Integration | start() 호출 | 포트 생성 + handshake 전송 |
| 2 | `testMCUChannelExecuteSetVolume` | Unit | execute mixer.set_volume track 0, 0.7 | PitchBend ch0 전송 |
| 3 | `testMCUFeedbackUpdatesFaderState` | Unit | PitchBend ch2 피드백 수신 | StateCache strip 2 volume 갱신 |
| 4 | `testMCUFeedbackUpdatesMuteState` | Unit | Note On 0x12 피드백 수신 | StateCache strip 2 mute = true |
| 5 | `testMCUFeedbackParsesLCD` | Unit | LCD SysEx 수신 | StateCache strip name 갱신 |
| 6 | `testMCUBankingAtomic` | Unit | track 12 명령 → 뱅킹 | bank→execute→restore 순서 보장 |
| 7 | `testMCUBankingQueueDuringBank` | Unit | 뱅킹 중 다른 명령 유입 | 큐에 대기 후 순차 실행 |
| 8 | `testMCUVerifyAfterWrite` | Unit | set_volume 후 피드백 대기 | 150ms 내 피드백 → success |
| 9 | `testMCUVerifyTimeout` | Unit | set_volume 후 피드백 없음 | 150ms 후 warning + success |
| 10 | `testMCUConnectionStateTracking` | Unit | 피드백 수신 시 | lastFeedbackAt 갱신 |
| 11 | `testMCUChannelStop` | Unit | stop() 호출 | 포트 해제 |
| 12 | `testBankingRoundTripUnder50ms` | Unit | bank+execute+restore 전체 | < 50ms |
| 13 | `testBankingRetryOnTrackCountChange` | Unit | 뱅킹 중 트랙 수 변경 감지 | 재뱅킹 + 재시도 (최대 2회) |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/MCUChannelTests.swift`
- `Tests/LogicProMCPTests/MCUFeedbackParserTests.swift`

### 3.3 Mock/Setup Required
- MockMIDITransport: 전송된 바이트 캡처 + fixture 피드백 주입
- StateCache: 실제 actor 인스턴스 (동시성 테스트)

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/MCUChannel.swift` | Create | MCU Channel actor |
| `Sources/LogicProMCP/MIDI/MCUFeedbackParser.swift` | Create | 피드백 → StateCache 갱신 |
| `Sources/LogicProMCP/State/StateCache.swift` | Modify | MCU 피드백 write 메서드 추가 |
| `Sources/LogicProMCP/State/StateModels.swift` | Modify | MCUConnectionState, TrackState.automationMode 추가 |
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Modify | MCUChannel 등록 |

### 4.2 Implementation Steps (Green Phase)
1. StateModels에 MCUConnectionState 추가, TrackState에 automationMode 추가 + PluginState, MCUDisplayState 추가. StateCache.automationMode 전역 필드 제거 (TrackState.automationMode로 대체)
2. StateCache에 MCU 피드백 전용 write 메서드 추가 (updateFader, updateButton, updateLCD)
3. MCUFeedbackParser 구현: 바이트 → StateCache 업데이트
4. MCUChannel actor: start/stop/execute/healthCheck
5. 뱅킹 트랜잭션 (isBanking lock + bankingQueue)
   > 타임아웃 분리: verify-after-write는 비뱅킹 단일 명령에만 적용(150ms). 뱅킹 내부는 waitForBankFeedback(100ms)로 별도 경로. ServerConfig에 mcuVerifyTimeoutMs(150), mcuBankFeedbackTimeoutMs(100) 별도 상수
6. verify-after-write (150ms 타임아웃)
7. 핸드셰이크 (Device Query → Response 대기)

## 5. Edge Cases
- EC-1: Logic Pro 미실행 → healthCheck unavailable (E1)
- EC-2: MCU 미등록 → 피드백 미수신 → registeredAsDevice=false (E3)
- EC-3: 뱅킹 중 트랙 추가/삭제 (E15)
- EC-4: 동시 다발적 명령 큐잉 (E9)

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] AC 전부 충족
- [ ] 뱅킹 동시성 안전
- [ ] swift build + swift test PASS
