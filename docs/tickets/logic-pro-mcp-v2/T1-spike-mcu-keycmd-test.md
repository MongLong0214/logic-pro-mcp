# T1: Phase 0 Spike — MCU 연결 + Key Commands + AX 트리 + 테스트 환경 실측

**PRD Ref**: PRD-logic-pro-mcp-v2 > §4.10 Phase 0, OQ-1/OQ-2/OQ-3
**Priority**: P0 (Blocker)
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: None

---

## 1. Objective
Phase 0 스파이크: MCU 가상 MIDI 포트가 Logic Pro 12.0.1에서 Mackie Control로 인식되는지, Key Commands .plist 직접 설치가 가능��지, AX 트리가 어떤 요소를 노출하는지 실측. 결과에 따라 PRD Appendix A 재산정.

## 2. Acceptance Criteria
- [ ] AC-1: CoreMIDI API로 가상 MIDI 소스+대상 포트를 생성하고, Logic Pro Control Surfaces에서 해당 포트를 MCU 장치 MIDI In/Out으로 할당할 수 있음을 실측 확인
- [ ] AC-2: MCU Device Query SysEx (`F0 00 00 66 14 00 F7`) 전송 후 Logic Pro 응답 수신 여부 실측 기록
- [ ] AC-3: `~/Library/Application Support/Logic/Key Commands/` 경로에 .plist 파일 배치 후 Logic Pro에서 인식되는지 실측 확인
- [ ] AC-4: Logic Pro 12.0.1의 AX 트리를 스캔하여 노출되는 최상위 요소 목록 기록 (window, groups, roles)
- [ ] AC-5: 실측 결과를 `docs/spike-results.md`에 기록하고 PRD Appendix A 커버리지 업데이트
- [ ] AC-6: `swift test` 통과 상태 유지
- [ ] AC-7: 핸드셰이크 3시나리오(성공/실패/무응답) 결과를 spike-results.md에 기록. 실패/무응답 시 T3/T4에서 registeredAsDevice=false 경로만 구현, 자동 핸드셰이크는 optional로 표기

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testVirtualMIDIPortCreation` | Integration | CoreMIDI 가상 포트 생성 후 시스템에 등록 확인 | 포트 이름이 MIDIGetNumberOfSources에서 검색됨 |
| 2 | `testMCUDeviceQuerySysEx` | Unit | MCU Device Query SysEx 바이트 생성 검증 | `[0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7]` |
| 3 | `testMCUSysExParsing` | Unit | MCU LCD SysEx 피드백 파싱 | offset + chars 올바르게 추출 |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/MCUProtocolTests.swift`
- `Tests/LogicProMCPTests/MIDIPortTests.swift`

### 3.3 Mock/Setup Required
- CoreMIDI 가상 포트: 실제 CoreMIDI API 사용 (loopback)
- AX 스캔: 실제 Logic Pro 12.0.1 실행 필요 (수동 실측, 자동화 테스트 ��님)

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/MIDI/MCUProtocol.swift` | Create | MCU SysEx 인코딩/디코딩 기초 |
| `Tests/LogicProMCPTests/MCUProtocolTests.swift` | Create | MCU 프로토콜 unit tests |
| `Tests/LogicProMCPTests/MIDIPortTests.swift` | Create | 가상 포트 생성 integration test |
| `docs/spike-results.md` | Create | 실측 결과 기록 |
| `docs/prd/PRD-logic-pro-mcp-v2.md` | Modify | Appendix A 실측 반영 |
| `Package.swift` | Modify | swift-testing dep added |

### 4.2 Implementation Steps (Green Phase)
1. `MCUProtocol.swift` 생성 — Device Query SysEx encode, LCD SysEx decode 기초
2. 테스트 작성 (Red 확인)
3. 최소 구현으로 테스트 통과 (Green)
4. Logic Pro 12.0.1 실행 상태에서 수동 실측:
   - CoreMIDI 가상 포트 생성 → Logic Pro Control Surfaces���서 포트 보이는지
   - MCU 등록 절차 기록 (수동/자동)
   - Key Commands .plist 경로 확인
   - AX 트리 스캔 (osascript 또는 Accessibility Inspector)
5. 결과를 `docs/spike-results.md`에 기록
6. Go/No-Go 판정: 핸드셰이크 성공 → T3/T4 full scope. 실패/무응답 → T3/T4 수동등록 전용 scope
7. PRD Appendix A 업데이트

### 4.3 Refactor Phase
- MCUProtocol을 §4.5 전체 스펙에 맞게 확장할 준비 (T3에서)

## 5. Edge Cases
- EC-1: Logic Pro가 실행되지 않은 상태에서 포트 생성 (E1)
- EC-2: 이미 동일 이름 포트 ��재 (E14)

## 6. Review Checklist
- [ ] Red: 테스트 실행 → FAILED 확인됨
- [ ] Green: 테스트 실행 → PASSED 확인됨
- [ ] Refactor: 테스트 실행 → PASSED 유지 확인됨
- [ ] AC 전부 충족
- [ ] 실측 결과 기록됨
- [ ] PRD Appendix A 업데이트됨
