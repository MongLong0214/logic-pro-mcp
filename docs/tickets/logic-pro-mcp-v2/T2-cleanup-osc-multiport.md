# T2: OSC 제거 + MIDIPortManager 멀티포트 + 기반 정비

**PRD Ref**: PRD-logic-pro-mcp-v2 > §4.6, §4.10 Phase 1
**Priority**: P1 (High)
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: T1

---

## 1. Objective
OSC 채널 완전 제거, MIDIPortManager actor로 멀티포트 관리, MIDIFeedback running status 수정, ChannelID enum 확장. Phase 2 MCU 채널 구현의 기반.

## 2. Acceptance Criteria
- [ ] AC-1: OSC 관련 파일 4개 삭제 (OSCChannel, OSCClient, OSCServer, OSCMessageBuilder)
- [ ] AC-2: ServerConfig에서 OSC 상수 제거
- [ ] AC-3: ChannelRouter에서 .osc 참조 전부 제거, 빌드 에러 0
- [ ] AC-4: MIDIPortManager actor가 포트 이름별 가상 MIDI 포트 생성/해제
- [ ] AC-5: MIDIFeedback.parseBytes가 running status 올바르게 처리
- [ ] AC-6: MIDIEngine.sendRawBytes가 MIDIPacketListAdd 반��값 검증
- [ ] AC-7: ChannelID enum에 .mcu, .midiKeyCommands, .scripter 추가
- [ ] AC-8: `swift build -c release` + `swift test` 모두 PASS

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testMIDIPortManagerCreatePort` | Unit | 포트 이름으로 생성 요청 | MIDIPort 인스턴스 반환 |
| 2 | `testMIDIPortManagerDuplicateName` | Unit | 동일 이름 포트 2회 생성 | 기존 포트 재사용 |
| 3 | `testMIDIPortManagerDispose` | Unit | stop() 호출 시 모든 포트 해제 | 포트 수 0 |
| 4 | `testMIDIFeedbackRunningStatus` | Unit | status byte 없는 연속 data bytes 파싱 | 이전 status 재사용 |
| 5 | `testMIDIFeedbackNormalParsing` | Unit | 기존 파싱 로직 regression | 기존 동작 유지 |
| 6 | `testChannelIDEnumContainsNewCases` | Unit | .mcu, .midiKeyCommands, .scripter 존재 | rawValue 접근 가능 |
| 7 | `testBuildWithoutOSC` | Integration | OSC 제거 후 전체 빌드 | 빌드 성공 |
| 8 | `testSendSysExValidation` | Unit | F0/F7 누락, 중간 바이트 0x80+ | reject + 에러 |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/MIDIPortManagerTests.swift`
- `Tests/LogicProMCPTests/MIDIFeedbackTests.swift`
- `Tests/LogicProMCPTests/ChannelIDTests.swift`

### 3.3 Mock/Setup Required
- MIDIPortManager: CoreMIDI 가상 포트 (실제 API, loopback)
- MIDIFeedback: fixture byte arrays

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/OSC/OSCChannel.swift` | Delete | |
| `Sources/LogicProMCP/OSC/OSCClient.swift` | Delete | |
| `Sources/LogicProMCP/OSC/OSCServer.swift` | Delete | |
| `Sources/LogicProMCP/OSC/OSCMessageBuilder.swift` | Delete | |
| `Sources/LogicProMCP/Server/ServerConfig.swift` | Modify | OSC 상수 제거 |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Modify | .osc 제거, 새 ChannelID 추가 |
| `Sources/LogicProMCP/Channels/Channel.swift` | Modify | ChannelID enum 확장 |
| `Sources/LogicProMCP/MIDI/MIDIPortManager.swift` | Create | 멀티포트 actor |
| `Sources/LogicProMCP/MIDI/MIDIFeedback.swift` | Modify | running status 처리 |
| `Sources/LogicProMCP/MIDI/MIDIEngine.swift` | Modify | sendRawBytes 반환값 검증 |
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Modify | OSCChannel 인스턴스 제거, OSC import 제거 |
| `Sources/LogicProMCP/main.swift` | Modify | OSC import 확인 |

### 4.2 Implementation Steps (Green Phase)
1. OSC 4파일 삭제
2. ServerConfig, ChannelRouter에서 OSC 참조 제거
3. ChannelID enum에 .mcu, .midiKeyCommands, .scripter 추가
4. MIDIPortManager actor 구현 (포트 생성/해제/조회)
5. MIDIFeedback.parseBytes running status 지원
6. MIDIEngine.sendRawBytes 반환값 검증
7. 테��트 작성 → Red → Green

## 5. Edge Cases
- EC-1: 포트 이름 충돌 (E14)
- EC-2: running status 후 SysEx (status 리셋)

## 6. Review Checklist
- [ ] Red → Green → Refactor 완료
- [ ] OSC 흔적 0 (grep 확인)
- [ ] swift build + swift test PASS
