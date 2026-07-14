# T6: Channel EQ verified 파라미터 확장 + rename_marker 스파이크 (PR-6)

**PRD Ref**: PRD-v39-hardening-and-midi-read > US-6
**Priority**: P2
**Size**: L (라이브 census 게이트)
**Status**: Todo
**Depends On**: None (머지 순서상 T5 이후; 라이브 세션 공유)
**Branch**: feat/v39-param-registry-eq

---

## 1. Objective
Channel EQ 파라미터를 라이브 census 증거 기반으로 verified param registry에 등재하고, 같은 라이브 세션에서 rename_marker AX 가능성을 판정한다. (applyback 브랜치 처분은 완료됨 — 델타 0, 삭제됨)

## 2. Acceptance Criteria
- [ ] AC-1 (게이트): 라이브 census 스파이크 — Channel EQ 에디터 AX 인벤토리. 산출물 `docs/spikes/channel-eq-census.md`: 파라미터별 canonical ID, AX role/description, 단위·범위·tolerance(dB/Hz/Q), 밴드 enable 동작, 에디터 창 전제조건, 라이브 E2E 케이스 정의. census 스크립트는 구현(기존 PluginInspector 활용), 실행/판정은 오케스트레이터
- [ ] AC-2: registry 등재 — 기존 `StockPluginParameterMetadata`/`VerifiedPluginCatalog` 패턴 확장(신규 타입 금지), census 증명 파라미터만(최소: 1개 밴드 gain+freq). Channel EQ는 insert-allowlist 기등재(AccessibilityChannel+VerifiedPlugins.swift:2345)
- [ ] AC-3: 미등재 파라미터 `unsupported_param_readback` fail-closed 유지 (기존 테스트 확장으로 가드)
- [ ] AC-4: strict 라이브 E2E에 Channel EQ verified write ≥1 케이스
- [ ] AC-5 (rename_marker 스파이크): 마커 리스트 AX 텍스트 편집 가능성 라이브 판정. PASS → 보정 티켓 T6b 생성 후 verified rename(State A) 구현, FAIL → `docs/spikes/rename-marker-evidence.md`에 증거 기록 + 기존 State C 유지

## 3. TDD Spec (Red Phase)

| # | Test Name | Type | Expected (Red) |
|---|-----------|------|----------------|
| 1 | `channelEQ_registry_entries_resolve_canonical_ids` | Unit | FAIL (엔트리 부재) |
| 2 | `channelEQ_gain_tolerance_math_db` / `freq_tolerance_hz` | Unit | FAIL |
| 3 | `set_param_verified_channelEQ_stateA_on_readback_within_tolerance` | Unit(mock AX) | FAIL |
| 4 | `set_param_verified_channelEQ_stateB_on_readback_mismatch` | Unit(mock AX) | FAIL |
| 5 | `unknown_channelEQ_param_fails_closed` | Unit | FAIL→가드 |

### Test File Location
- `Tests/LogicProMCPTests/VerifiedPluginCatalogTests.swift` 계열 확장 (기존 Compressor threshold 테스트 패턴 미러)

### 주의
- tolerance/범위 값은 census artifact의 실측만 사용 — 추정 금지
- Hz 파라미터는 로그 스케일 가능성 — census에서 AX 값 단위(실제 Hz vs 정규화 0-1) 확인 후 tolerance 정의
- dead-#expect 금지

## 4. Implementation Guide

| File | Change |
|------|--------|
| Sources/LogicProMCP/…/StockPluginCatalog.swift, VerifiedPluginCatalog.swift | EQ 엔트리 |
| Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift | (필요 시) EQ 에디터 특이 처리 |
| Scripts/spike-channel-eq-census.py (신규, 구현) | census 프로브 |
| docs/spikes/channel-eq-census.md, docs/API.md, README.md 제한사항 문구 | 문서 |
| Scripts/live-e2e-test.py | EQ 케이스 |

검증: `swift test --no-parallel` + strict 라이브 E2E.

## 5. Edge Cases (PRD E8)
- EC-1: 에디터 미오픈 → 기존 insert_verified 선행 경로 재사용, 실패 State C
- EC-2: census와 다른 Logic 버전 AX 구조 → registry는 readback 실패 시 State B로 정직 강등 (기존 계약)

## 6. Review Checklist
- [ ] census artifact 존재 + registry 값이 artifact와 1:1
- [ ] Red FAILED → Green PASSED → Refactor 유지
- [ ] 라이브 E2E EQ 케이스 PASS (또는 honest defer 기록)
- [ ] rename_marker 판정 기록 존재
