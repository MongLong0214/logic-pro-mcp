# T5b: MIDI 읽기 표면 — T0 스파이크 + read_selection_notes + verify_notes (PR-5 후반부)

**PRD Ref**: PRD-v39-hardening-and-midi-read > US-5 (AC-5.1, 5.3~5.5, 5.7)
**Priority**: P1
**Size**: L
**Status**: Todo
**Depends On**: T5a
**Branch**: feat/v39-midi-read

---

## 1. Objective
T0 라이브 게이트 통과 후 AX export 파이프라인과 공개 표면(`read_selection_notes`, `record_sequence verify_notes`)을 구현한다. T0 FAIL 시 이 티켓 전체 honest defer(PR-5는 T5a만 출하 여부를 오케스트레이터가 판단).

## 2. Acceptance Criteria
- [ ] AC-1 (T0 게이트): 라이브 스파이크 — record_sequence sentinel region 생성 → region 선택 → File>Export>Selection as MIDI File(locale-agnostic) → save 다이얼로그 통제 디렉토리 유도 → 파일 생성 + SMFReader 파싱 노트가 sentinel 일치. 산출물 `docs/spikes/midi-export-t0-evidence.md`. 스파이크 스크립트는 구현(`Scripts/spike-midi-export.py` — live-e2e probe 패턴: popen, initialized 핸드셰이크, tools/call args는 "params" 아래), 실행/판정 오케스트레이터. 사용자 프로젝트 파괴 금지: 신규 트랙에 생성, 종료 시 undo/트랙 삭제 원복
- [ ] AC-2: `logic_midi.read_selection_notes` — State A 조건: (a) export 파일 신규 생성(사전 부재+mtime/size), (b) 파싱 성공, (c) 선택 identity(region/track) 사전 AX 캡처 + evidence 포함. identity 불가 → State B. RoutingTable `midi.read_selection_notes` → [.accessibility]
- [ ] AC-3: `record_sequence verify_notes:true`(기본 false) — 기존 선택/플레이헤드 캡처 → 생성 region 결정론 선택(기존 enumeration identity) → 선택 검증 실패 시 export 없이 State B → export→파싱→노트 대조 일치 State A(노트 evidence) → 이전 선택 복원. verify_notes=false 경로는 기존 동작 무변경
- [ ] AC-4: 빈 선택/오디오 region → State C `no_midi_selection`, export 노트 0 → State B `export_empty`, 다이얼로그 잔류 금지(Escape 폴백)
- [ ] AC-5: docs/API.md + CHANGELOG + strict 라이브 E2E에 read_selection_notes 케이스

## 3. TDD Spec (Red Phase)
T5 원본 §3의 #5~#9 (read_selection_notes State A/B/C mock 테스트, verify_notes State A/B + 기본값 회귀) — mock AX로 유닛 검증, Red FAIL.

### Test File Location
- `Tests/LogicProMCPTests/MIDIReadSelectionTests.swift` (신규) + TrackDispatcher 기존 테스트 확장

## 4. Implementation Guide
| File | Change |
|------|--------|
| Sources/LogicProMCP/Channels/AccessibilityChannel+MIDIExport.swift (신규) | 메뉴/다이얼로그/identity (T0 증거 기반) |
| Sources/LogicProMCP/Dispatchers/MIDIDispatcher.swift, TrackDispatcher+RecordSequence.swift | 커맨드/파라미터 |
| Sources/LogicProMCP/Channels/RoutingTable.swift | 라우트 |
| docs/API.md, CHANGELOG.md, Scripts/live-e2e-test.py | 표면 |

검증: `swift test --no-parallel` + strict 라이브 E2E + T0 evidence.

## 5. Edge Cases
PRD E3/E5/E9 → §2 AC-4. 

## 6. Review Checklist
- [ ] T0 evidence 문서 존재(또는 defer 기록) / Red→Green→Refactor / verify_notes=false byte-동일 / AC 전부
