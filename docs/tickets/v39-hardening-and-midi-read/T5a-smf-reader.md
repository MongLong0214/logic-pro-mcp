# T5a: SMFReader + Export 임시파일 매니저 (PR-5 전반부)

**PRD Ref**: PRD-v39-hardening-and-midi-read > US-5 (AC-5.2, AC-5.3의 파일 통제 부분)
**Priority**: P1
**Size**: M
**Status**: Todo
**Depends On**: None
**Branch**: feat/v39-midi-read

---

## 1. Objective
라이브 Logic 없이 완결되는 순수 유닛 파트: SMF 파서와 export 전용 임시파일 매니저. (independent review 티켓리뷰 #1로 T5에서 분할)

## 2. Acceptance Criteria
- [ ] AC-1: `SMFReader` — format 0/1, division(PPQN) tick→bar/beat, tempo/time-sig meta, note on/off 페어링. 노트 출력: `pitch, velocity, start_bar, start_beat, duration_beats, channel(1-based)`
- [ ] AC-2: 필수 fixture 전수 — running status, velocity-0 note-off, 동일 pitch/channel 중첩, SMPTE division 거부, VLQ/track-length 경계, format-1 멀티트랙 tempo 병합. malformed = fail-closed(부분 결과 금지)
- [ ] AC-3: SMFWriter 산출물 round-trip (record_sequence가 쓰는 실제 Writer 출력 → Reader → 노트 일치)
- [ ] AC-4: `ExportTemporaryFiles` — SMFWriter+TemporaryFiles 대칭: 전용 디렉토리 생성, 레지스트리, symlink escape 방지, cleanup, 테스트

## 3. TDD Spec (Red Phase)
T5 원본 §3의 #1~#4 항목 전부 (roundtrip, fixture ×7, malformed, 레지스트리 ×3) — 모두 유닛, 라이브 불필요, Red에서 FAIL.

### Test File Location
- `Tests/LogicProMCPTests/SMFReaderTests.swift`, `ExportTemporaryFilesTests.swift` (신규)

### 주의
- dead-#expect 금지. Swift 6 concurrency 준수. 기존 SMFWriter 스타일 미러

## 4. Implementation Guide
| File | Change |
|------|--------|
| Sources/LogicProMCP/MIDI/SMFReader.swift (신규) | 파서 |
| Sources/LogicProMCP/MIDI/ExportTemporaryFiles.swift (신규) | 매니저 |
| Tests/… ×2 (신규) | 위 테스트 |

검증: `swift test --no-parallel`.

## 5. Edge Cases
PRD E4(달린 노트 fail-closed) 포함, §2 AC-2 전수.

## 6. Review Checklist
- [ ] Red FAILED → Green PASSED → Refactor 유지 / AC 전부 / 기존 테스트 무파손
