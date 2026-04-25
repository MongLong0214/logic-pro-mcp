# PRD — Logic Pro MCP v3.1.0 "Honest Contract"

**Status**: Approved
**Size**: L
**Level**: 1.5 (비가역 없음, 외부 유저 계약 영향 → 3자 합의 필요)
**Authored**: 2026-04-24
**Owner**: Isaac (weplay0628@gmail.com)

---

## 1. Problem Statement

v3.0.9 Guardian 전수감사 결과 **FAIL**. 핵심 문제: 여러 mutating operation이 AX write 결과를 검증 없이 success로 리턴하여, 클라이언트(Claude/LLM agent)가 실제로는 실패한 호출을 성공으로 해석하는 "정직하지 않은 계약"이 다수 존재.

### 구체 결함
| # | 위치 | 증상 |
|---|------|------|
| P0-1 | `AccessibilityChannel.swift:1766-1773` | `set_instrument`가 `selectPath` 내부 리턴을 read-back 없이 success로 포장. 잘못된 패치가 로드되어도 클라는 모름 |
| P1-1 | `AXLogicProElements.swift` `selectTrackViaAX` | `AXSelectedChildren` write 후 `verified:false`여도 HTTP success. honest contract 위배 |
| P1-2 | `MCUChannel.swift:148/161/169` | `set_volume/pan/master_volume` MCU bytes 송신만. Logic echo(fader position feedback) 확인 안 함 |
| P1-3 | `transport.set_cycle_range` AX path (line 637) | `verified` 필드 없음 — osascript fallback과 스키마 불일치 |
| P1-4 | `README.md:154` | "every patch addressable" 허위. disk-only 엔트리는 `resolve_path` success지만 `selectPath`는 실패 |
| P1-5 | `scan_library {mode:disk}` | lastScan 캐시 오염 → panel 전용 쿼리에도 disk 엔트리 혼입 |
| P2 | state resources | `cache_age_sec` 없음 → 클라가 stale 판단 불가 |

## 2. Goals / Non-Goals

### Goals
1. 모든 mutating operation이 **Honest Contract** 불변식 준수
2. 클라이언트가 `verified` 필드로 확정 성공 vs 불확실 vs 실패를 명확히 구분 가능
3. v3.0.9 사용자가 **breaking change 없이** 업그레이드 가능 (additive 필드 + 기존 success 경로 유지)
4. 3+ 사이클 live Logic Pro 검증 후 릴리즈

### Non-Goals
- 신규 기능 추가
- AX API 외 새 통신 채널 추가
- v3.0.9 이전 버전 역호환

## 3. Honest Contract 규약 (Invariants)

모든 mutating operation은 아래 3-state 중 하나를 반드시 반환:

### State A — `success: true, verified: true`
AX write 성공 + read-back으로 실제 상태 확인 완료.

```json
{"success": true, "verified": true, "requested": "Classic Suitcase Mk IV", "observed": "Classic Suitcase Mk IV"}
```

### State B — `success: true, verified: false`
AX write는 성공(kAXErrorSuccess 또는 Logic에 bytes 도달)했으나 read-back 불가/타임아웃/mismatch. 클라에게 **불확실성 명시**.

```json
{"success": true, "verified": false, "reason": "echo_timeout_500ms", "requested": 100, "observed": null}
```

`reason` enum:
- `echo_timeout_<ms>` — MCU feedback 타임아웃
- `readback_unavailable` — AX read-back attribute 미노출
- `readback_mismatch` — write 성공했으나 read 값이 다름 (SMF fresh track lag 등). `track.select`의 경우 다른 index가 선택됨.
- `retry_exhausted` — retry 6회(100ms 간격, 총 600ms) 후에도 read-back 메타데이터 surface 안 됨. 값 mismatch와는 분리됨(그쪽은 `readback_mismatch`).

### State C — `success: false, error: <...>`
AX write 자체 실패 (kAXError 반환 등). 재시도해도 의미 없음.

```json
{"success": false, "error": "ax_write_failed", "axCode": -25212, "hint": "…"}
```

### 규약 위반 = 버그
- `success:true, verified` 필드 없음 → 위반
- `verified:false` 로 돌려주면서 `reason` 없음 → 위반
- `success:true` 인데 read-back 호출 코드가 아예 없음 → 위반 (verified 필드 존재해도)

## 4. Scope — Ticket Inventory

| ID | Title | Priority | Files |
|----|-------|----------|-------|
| T2 | set_instrument read-back | P0 | AccessibilityChannel.swift, LibraryAccessor.swift |
| T3 | track.select verified 엄격화 | P1 | AXLogicProElements.swift |
| T4 | MCU mixer echo 폴링 | P1 | MCUChannel.swift, MCUEchoListener (신규) |
| T5 | set_cycle_range verified | P1 | AccessibilityChannel.swift |
| T6 | scan_library cache 분리 | P1 | LibraryAccessor.swift, LibraryDiskScanner.swift |
| T7 | cache_age_sec in resources | P2 | Resources/*.swift |
| T8 | README + CHANGELOG 정직화 | P1 | README.md, CHANGELOG.md |

## 5. Key Risks

1. **MCU echo timing 불확정** — fader feedback은 Logic 버전/프로젝트 로드 상태에 따라 지연 편차 큼. 500ms 고정이 부족하면 false negative. **Mitigation**: 250/500/1000ms 윈도우 A/B 라이브 측정 후 결정. 기본 500ms + env override.
2. **SMF-fresh track 지연** — 갓 생성된 트랙은 AX tree에 늦게 반영됨. track.select를 엄격 error로 바꾸면 기존 스크립트가 깨질 수 있음. **Mitigation**: retry 6회(100ms interval, 총 600ms) — 메타데이터가 아예 surface 안 되면 `verified:false + reason:retry_exhausted`, 메타데이터는 surface 됐지만 다른 index가 선택된 경우는 `readback_mismatch`. 엄격 error는 AX write 자체 실패 시에만.
3. **Library Panel read-back 방식 확정** — 선택된 patch name은 `Inventory.currentPreset`(AXList의 `AXSelectedChildren` → 첫 selected child의 `AXValue`)으로 읽는다. Ralph-2 시점 기준 channel-strip plugin-name 2차 근거 폴백은 미구현(필요 시 후속 릴리즈에서 `PluginInspector.topInstrumentName` 기반 구현).

## 6. Acceptance Criteria

- [ ] 모든 mutating op (`set_instrument`, `track.select`, `mixer.*`, `set_cycle_range`)가 3-state 반환
- [ ] `verified:false` 시 `reason` 필드 **반드시** 존재
- [ ] `success:false` 시 `error` 필드 **반드시** 존재 (string enum)
- [ ] Live Logic Pro에서 각 op 3+ 사이클 검증 후 PASS
- [ ] `scan_library {mode:disk}` 호출 후 panel 전용 쿼리가 오염되지 않음
- [ ] `logic://tracks`, `logic://library/inventory` 에 `cache_age_sec` 필드 포함
- [ ] README + CHANGELOG 업데이트: "every patch" 삭제, verified 필드 규약 문서화
- [ ] 빌드 3종 (swift build --configuration release / swift test / swift format lint) 통과
- [ ] `docs/HONEST-CONTRACT.md` 클라이언트 가이드 추가

## 7. Phase 1 실행 순서

1. **T2 (P0)** — set_instrument read-back: Library Panel AX dump → attribute 확정 → 구현 + 테스트
2. **T3 (P1)** — track.select 엄격화: 기존 코드에 retry/3-state 반환 주입
3. **T5 (P1)** — set_cycle_range verified 필드 추가 (단일 read-back, 리스크 최저 → T3 직후)
4. **T4 (P1)** — MCU echo 폴링: MCUEchoListener 신규 (가장 복잡, 시간 가장 많이 소요)
5. **T6 (P1)** — scan_library cache 분리 (독립적)
6. **T7 (P2)** — cache_age 필드 (모든 resource 일괄)
7. **T8** — 문서 업데이트 (마지막)

## 8. Definition of Done

- Phase 2 Guardian + Boomer ALL PASS
- Live Logic Pro 검증 (10+ 호출) 통과
- v3.1.0 태그 + Formula SHA256 동기화 + GitHub release 발행
- CHANGELOG v3.1.0 entry
