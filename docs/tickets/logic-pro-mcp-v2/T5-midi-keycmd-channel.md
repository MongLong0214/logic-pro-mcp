# T5: MIDI Key Commands 채널 + 프리셋 생성

**PRD Ref**: PRD-logic-pro-mcp-v2 > US-4, US-5, US-8, §4.11
**Priority**: P1 (High)
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T2

---

## 1. Objective
MIDIKeyCommandsChannel 구현: MIDI CC → Logic Pro Key Command 트리거. CC 매핑 테이블(§4.11) 기반. 프리셋 .plist 생성기 + 설치/백업/복구 스크립트.

## 2. Acceptance Criteria
- [ ] AC-1: MIDIKeyCommandsChannel이 Channel 프로토콜 구현
- [ ] AC-2: execute("edit.undo") → MIDI CC 30 on CH 16 전송
- [ ] AC-3: execute("track.create_audio") → MIDI CC 20 on CH 16 전송
- [ ] AC-4: §4.11 매핑 테이블 전체 (CC 20-93) 구현
- [ ] AC-5: Scripts/keycmd-preset.plist 생성 (Logic Pro Key Commands 포맷)
- [ ] AC-6: Scripts/install-keycmds.sh — 기존 매핑 백업 + 프리셋 설치 + 충돌 감지
- [ ] AC-7: Scripts/uninstall-keycmds.sh — 백업에서 복원

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testKeyCommandMappingUndo` | Unit | "edit.undo" → CC# | CC 30 |
| 2 | `testKeyCommandMappingCreateAudio` | Unit | "track.create_audio" → CC# | CC 20 |
| 3 | `testKeyCommandMappingToggleMixer` | Unit | "view.toggle_mixer" → CC# | CC 50 |
| 4 | `testKeyCommandAllMappingsUnique` | Unit | 전체 매핑에서 CC# 중복 없음 | unique count == total |
| 5 | `testKeyCommandChannelExecute` | Unit | execute 호출 �� MIDI 바이트 생성 | CC message on CH 16 |
| 6 | `testKeyCommandUnknownOperation` | Unit | 미등록 operation | error 반환 |
| 7 | `testKeyCommandMappingCount` | Unit | 매핑 총 개수 | >= 30 (§4.11 기준) |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/MIDIKeyCommandsTests.swift`

### 3.3 Mock/Setup Required
- MockMIDITransport: 전송된 바이트 캡처

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/MIDIKeyCommandsChannel.swift` | Create | Key Commands 채널 |
| `Scripts/keycmd-preset.plist` | Create | Logic Pro Key Commands 프리셋 |
| `Scripts/install-keycmds.sh` | Create | 설치 + 백업 |
| `Scripts/uninstall-keycmds.sh` | Create | 복원 |
| `Tests/LogicProMCPTests/MIDIKeyCommandsTests.swift` | Create | 테스트 |
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Modify | MIDIKeyCommandsChannel 등록 |

### 4.2 Implementation Steps (Green Phase)
1. 매핑 테이블 딕셔너리 정의 (operation → CC#)
2. MIDIKeyCommandsChannel actor: execute → CC 전송
3. healthCheck: MIDIPortManager에서 포트 상태 확인
4. 테스트 작성 → Red → Green
5. T1 spike-results.md의 Key Commands .plist 포맷 확인 후 keycmd-preset.plist 생성
6. install-keycmds.sh / uninstall-keycmds.sh 작성

## 5. Edge Cases
- EC-1: 프리셋 미설치 → CGEvent fallback (E6)
- EC-2: CC 충돌 감지 (§6.3)

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] §4.11 매핑 전체 커버
- [ ] 스크립트 실행 테스트 (수동)
