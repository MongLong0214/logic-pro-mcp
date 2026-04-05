# T3: MCU 프로토콜 인코더/디코더

**PRD Ref**: PRD-logic-pro-mcp-v2 > §4.5 MCU Protocol Specification
**Priority**: P0 (Blocker)
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: T1, T2

---

## 1. Objective
§4.5 MCU 프로토콜 스펙을 Swift로 완전 구현. Fader, Button, V-Pot, Transport, Banking, Automation, LCD SysEx, Jog Wheel의 인코딩(command 전송용) + 디코딩(feedback 파싱용).

## 2. Acceptance Criteria
- [ ] AC-1: MCU fader 인코딩: track index + value(0.0-1.0) → Pitch Bend 메시지 (14-bit)
- [ ] AC-2: MCU fader 디코딩: Pitch Bend 수신 → track index + normalized value
- [ ] AC-3: MCU button 인코딩: function(mute/solo/arm/select) + strip(0-7) + on/off → Note On/Off
- [ ] AC-4: MCU button 디코딩: Note On/Off → function + strip + state
- [ ] AC-5: MCU transport 인코딩: play/stop/record/rewind/ff/cycle → Note On
- [ ] AC-6: MCU V-Pot 인코딩: strip + direction + speed → CC
- [ ] AC-7: MCU banking 인코딩: bankLeft/bankRight/channelLeft/channelRight → Note On
- [ ] AC-8: MCU LCD SysEx 디코딩: SysEx → offset + text (upper/lower row 분리)
- [ ] AC-9: MCU automation 인코딩: mode(read/write/touch/latch) → Note On
- [ ] AC-10: MCU jog wheel 인코딩: direction + clicks → CC 0x3C
- [ ] AC-11: MCU handshake: Device Query encode + Response decode
- [ ] AC-12: 전체 테스트 PASS

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testEncodeFaderPosition` | Unit | track 0, value 0.5 | PitchBend ch0, value 0x2000 |
| 2 | `testEncodeFaderMax` | Unit | track 7, value 1.0 | PitchBend ch7, value 0x3FFF |
| 3 | `testDecodeFaderFeedback` | Unit | PitchBend ch3 value 0x1000 | track 3, ~0.25 |
| 4 | `testEncodeMuteButton` | Unit | mute strip 2 on | Note On 0x12, vel 0x7F |
| 5 | `testDecodeSOloLED` | Unit | Note On 0x0A, vel 0x7F | solo strip 2 on |
| 6 | `testEncodeTransportPlay` | Unit | play | Note On 0x5E, vel 0x7F |
| 7 | `testEncodeTransportStop` | Unit | stop | Note On 0x5D, vel 0x7F |
| 8 | `testEncodeVPotCW` | Unit | strip 0, speed 3 | CC 0x10, value 0x03 |
| 9 | `testEncodeVPotCCW` | Unit | strip 0, speed 3 | CC 0x10, value 0x43 |
| 10 | `testEncodeBankRight` | Unit | bankRight | Note On 0x2F, vel 0x7F |
| 11 | `testDecodeLCDSysEx` | Unit | F0 00 00 66 14 12 00 48 65 6C 6C 6F F7 | offset 0, "Hello" |
| 12 | `testDecodeLCDUpperRow` | Unit | offset 0x00-0x37 | row: upper |
| 13 | `testDecodeLCDLowerRow` | Unit | offset 0x38-0x6F | row: lower |
| 14 | `testEncodeAutomationTouch` | Unit | touch | Note On 0x4D, vel 0x7F |
| 15 | `testEncodeJogCW` | Unit | 1 click CW | CC 0x3C, value 0x01 |
| 16 | `testEncodeDeviceQuery` | Unit | handshake query | F0 00 00 66 14 00 F7 |
| 17 | `testDecodeDeviceResponse` | Unit | F0 00 00 66 14 01 ... F7 | isConnected = true |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/MCUProtocolTests.swift` (T1에서 생성, 여기서 확장)

### 3.3 Mock/Setup Required
- 순수 함수 테스트, mock 불필요. 바이트 배열 fixture만.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/MIDI/MCUProtocol.swift` | Modify | T1 기초에서 전체 스펙 구현 |
| `Tests/LogicProMCPTests/MCUProtocolTests.swift` | Modify | 17개 테스트 추가 |

### 4.2 Implementation Steps (Green Phase)
1. `MCUProtocol` 구조체에 encode/decode static 메서드 추가
2. Fader encode/decode (Pitch Bend ↔ track+value)
3. Button encode/decode (Note On/Off ↔ function+strip+state)
4. Transport encode (play/stop/record/rewind/ff/cycle)
5. V-Pot encode (relative CC)
6. Banking encode
7. LCD SysEx decode (offset + text 추출)
8. Automation encode
9. Jog Wheel encode
10. Handshake encode/decode

### 4.3 Refactor Phase
- MCUProtocol 내부를 Message enum으로 구조화 (encode: Message → [UInt8], decode: [UInt8] → Message)

## 5. Edge Cases
- EC-1: LCD SysEx에 non-ASCII 바이트 (E8)
- EC-2: Fader value 범위 초과 (clamp to 0.0-1.0)
- EC-3: 빈 SysEx 데이터

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] §4.5 스펙 전체 커버
- [ ] 17개 테스트 PASS
