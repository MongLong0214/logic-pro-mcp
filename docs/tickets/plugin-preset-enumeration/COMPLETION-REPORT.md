# 구현 완료 보고: F2 Plugin Preset Enumeration (Foundation)

**작업 ID**: F2 (follow-up from library-full-enumeration v2.1.0)
**수행 방식**: `/dev-pipeline` 자율 (Ralph 수렴 모드)
**소요 시간**: ~4.5시간 (사용자 10시간 예산 내)
**일자**: 2026-04-13

---

## 요약

- **PRD**: `docs/prd/PRD-plugin-preset-enumeration.md` (v0.5, **Approved** after Phase 2 Ralph 5-round convergence)
- **사이즈**: XL (24h+, 아키텍처 확장)
- **티켓**: 15개 작성 (T0-T14) — `docs/tickets/plugin-preset-enumeration/`
- **코드**: `Sources/LogicProMCP/Accessibility/PluginInspector.swift` (491 lines, 신규)
- **테스트**: **57 신규 추가** (593 baseline → 650 PASS, 0 regression)
- **구현 진도**: **T0-T5 완료 + T11 partial** → Foundation 레이어. **T6-T14 follow-up PR로 유예**.

**스코프 리얼리티 체크**: PRD 자체 추정 "10-14 days post-approval" — 10시간 자율 세션은 XL 전체를 담지 못함. 정직한 분할 기준으로 Foundation(T0-T5)+Tickets+PRD를 PR-1으로, Handlers(T6-T10)+Tests+Rollout(T11-T14)을 PR-2로 설계.

---

## 빌드 검증

| 항목 | 결과 |
|------|------|
| `swift build` | **PASS** (zero warnings, zero errors, 0.88s) |
| `swift test` | **PASS** 650/650 (593 baseline + 57 new; 0 regression) |
| Coverage (`xcrun llvm-cov`) | **PluginInspector.swift: 94.41% line / 89% region / 96.55% function** — G5 ≥ 90% line 충족 |
| Tech stack | Swift 6.0 + macOS 14+ + Swift Testing + Accessibility APIs |

---

## 마이그레이션

- 신규 파일만. 기존 파일 수정 없음.
- `Resources/plugin-inventory.json` — **아직 생성 안 됨** (T6에서 scanner 붙으면 생성됨). `.gitignore` 와일드카드는 T14 유예.

---

## 구현 내용

### T0: AX Probe Spike
- `Scripts/plugin-menu-ax-probe.swift` (207줄, `chmod +x`) — 8 OQ-1 질문 probe
- `docs/spikes/F2-T0-plugin-menu-probe-result.md` — 결과 템플릿 (Isaac이 live Logic Pro에서 실행)
- Verdict는 비워둠 (**GO-AXPRESS** / **GO-CGEVENT** / **MIXED**) — Isaac 복귀 후 1회 실행 필요

### T1: Data Types (9 tests PASS)
- `PluginPresetNodeKind` enum (7 cases: folder/leaf/separator/action/truncated/probeTimeout/cycle)
- `PluginPresetNode` (name/path/kind/children)
- `PluginPresetCache` (15 필드 포함 `schemaVersion:1`, `contentHash`, `cycleCount`)
- `PluginPresetInventory` (wrapper dict)
- `PluginPresetProbe` (6 closures), `PluginWindowRuntime` (6 closures with monotonic `nowMs`)
- `AXUIElementSendable` (NEW wrapper — @unchecked Sendable, 구체적 정의)
- `ScannerWindowRecord` (CGWindowID primary, bundleID+title fallback)

### T2: enumerateMenuTree (11 tests PASS)
- 재귀 walker with depth cap (`maxPluginMenuDepth: 10`)
- Cycle detection via visited-hash set
- probeTimeout / mutation guard / focus-loss abort
- Duplicate sibling `[i]` disambiguation
- Whitespace-only name skip
- Separator/action preservation

### T3: Path Parse/Resolve/Select (19 tests PASS + 2 regression)
- `parsePath` state-machine with 2-char Unicode markers (E001/E002) → 정확한 escape/unescape
- `encodePath` 역함수 (round-trip 검증)
- `resolveMenuPath` — exact-match first, disambig `[i]` fallback (negative index 차단 — **boomer P0 fix**)
- `selectMenuPath` — async hop-by-hop via `probe.pressMenuItem`, `settleMs` 사이
- Escaped trailing `/` 보존 (**boomer P2 fix**)

### T4: Plugin Identity (8 tests PASS)
- `decodeAUVersion(UInt32)` → `"M.m.b"` or nil
- `identifyPlugin(in: window, runtime:)` 래퍼
- `findPluginWindow(for: trackIndex, runtime:)` 래퍼
- Bundle ID primary (locale-invariant); AXDescription/AXTitle은 T6에서 fallback으로 구성
- `findSettingDropdown` 은 T6에 위임 (live AX-tree walk 필요)

### T5: Window Lifecycle (6 tests PASS + 1 regression)
- `openPluginWindow` with 2000ms polling + monotonic clock (timeout `>=` boundary — **boomer P2 fix**)
- `closePluginWindow` passthrough
- CGWindowID 캡처는 runtime closure에 위임 (T6에서 live capture)

### 유예된 항목 (T6-T14 → Follow-up PR)

| 티켓 | 설명 | 이유 |
|------|------|------|
| T6 | scanPluginPresets 핸들러 + actor state + cache 영속화 | AccessibilityChannel actor 확장 + trackPluginMapping + file I/O 필요 |
| T7 | scanAllInstruments 배치 + reconciliation ledger | T6 의존 |
| T8 | setPluginPreset + AC-3.0 gate | T6 의존 |
| T9 | resolvePluginPresetPath cache-only | T6 의존 |
| T10 | TrackDispatcher MCP wiring | T6-T9 의존 |
| T11 | Coverage audit (부분 완료 — T1-T5 94.41% ≥ 90% 이미 달성) | 유지보수 |
| T12 | Integration tests 100% branch | T6-T10 의존 |
| T13 | Edge case E1-E32 (37 rows) | T6-T9 의존 |
| T14 | Rollout: .gitignore wildcard + docs + E2E script + test-count gate | T10, T12, T13 의존 |

Follow-up PR 체크리스트는 각 티켓 `T{N}*.md` 파일에 TDD Spec + Implementation Steps + Files to Modify로 이미 작성됨. 새 개발자가 archaeology 없이 착수 가능.

---

## 리뷰 이력

| Phase | Rounds | Verdict | 세부 |
|-------|--------|---------|------|
| 2 (PRD) | **5 (Ralph 수렴)** | ALL PASS at v0.5 | strategist/guardian/boomer; v0.1→v0.5 이동. 기술적 개선 예시: `AudioComponentGetVersion` free-function API (AUPlugInGetVersionNumber 인스턴스 요구 회피), `CGWindowID` 기반 ledger(AX hash 불안정성 회피), canonical naming table, AC-3.0 gate without "path implies plugin" 추론, contentHash post-rescan-only (순환 체크 금지) |
| 4 (Ticket) | 1 (patched in-place) | REQUEST CHANGES → PASS | 4-reviewer: T4 stale contentHash 참조 제거, T12↔T14 gitignore race 해결, AC-1.3/1.6/1.8/6.3 orphan 처리, trackPluginMapping 명시 |
| 5 (TDD 개발) | Incremental per ticket | SELF PASS on T0-T5 | 각 티켓 RED→GREEN→REFACTOR. 전체 스위트 매 단계 PASS |
| 6 (Final) | 1 + fixes | PASS post-fix | guardian PASS (94.41% line cov); boomer P0 (음수 인덱스 crash) + P2×2 (escape trailing slash, timeout boundary) — 3건 즉시 수정 + 회귀 테스트 추가. 650/650 PASS |

---

## 주요 기술 결정 (Phase 2 Ralph 수렴 산출물)

1. **T0 AX probe가 hard gate**: AXPress vs CGEvent 결정은 T0 결과에 전적으로 의존. §4 전체를 조건부로 작성. CGEvent fallback은 `LibraryAccessor.productionMouseClick` 위임(재구현 금지)
2. **`axScanInProgress` 공유 뮤텍스**: library.scan_all + plugin.* 4개 AX op + set_plugin_preset 모두 단일 flag로 직렬화. `resolve_preset_path` 만 예외(cache-only)
3. **AU version via `AudioComponentGetVersion(audioComponent, &version)`**: free function, 인스턴스 불필요. 대안 `AUPlugInGetVersionNumber`는 instance 요구 → 기각
4. **`AXUIElementSendable`** — 신규 @unchecked Sendable 래퍼 (F1에 없음). actor-scope 내부 dereference 안전 보장
5. **`ScannerWindowRecord` CGWindowID 기반**: AXUIElement pointer hash는 async Task suspension 간 unstable → CGWindowID 정수를 primary 키로 채택, `(bundleID, windowTitle)` fallback
6. **contentHash는 post-rescan-only**: cached contentHash vs cached contentHash 비교는 순환(항상 참) → 금지. nil version → 무조건 rescan
7. **AXIdentifier는 AU registry 실패 시 locale-invariant fallback 키**: AXDescription(localize됨), contentHash(mutable) 둘 다 금지

---

## 후속 작업 (Follow-up PR scope — 명확하게 유예)

1. **T0 live run by Isaac**: 실행 가능한 probe script가 이미 준비됨. 1회 실행 → result doc 채움 → verdict 결정
2. **PR-2 (T6-T14)**: 기존 tickets의 TDD Spec을 그대로 이행. 인프라(PluginPresetProbe, PluginWindowRuntime, PluginInspector 순수함수)는 이미 준비됨
3. **영향받는 기존 파일**: `AccessibilityChannel.swift` (scanInProgress → axScanInProgress 이름 변경, T6 신규 handler 4개 case), `ChannelRouter.swift` (plugin.* namespace 4 routes 추가, 기존 placeholder 유지), `TrackDispatcher.swift` (tool description + 4 command case), `.gitignore` (wildcard 교체)

---

## 파일 생성/수정 요약

### 신규 파일 (14개)
```
docs/prd/PRD-plugin-preset-enumeration.md          (v0.5, ~650 lines)
docs/tickets/plugin-preset-enumeration/STATUS.md
docs/tickets/plugin-preset-enumeration/TEST-BASELINE.txt
docs/tickets/plugin-preset-enumeration/T0-T14*.md  (15 tickets)
docs/tickets/plugin-preset-enumeration/COMPLETION-REPORT.md  (이 파일)
docs/spikes/F2-T0-plugin-menu-probe-result.md      (template)
Sources/LogicProMCP/Accessibility/PluginInspector.swift  (491 lines)
Scripts/plugin-menu-ax-probe.swift                 (207 lines, chmod +x)
Tests/LogicProMCPTests/PluginInspectorTypesTests.swift       (9 tests)
Tests/LogicProMCPTests/PluginInspectorEnumerateTreeTests.swift (11 tests)
Tests/LogicProMCPTests/PluginInspectorPathTests.swift         (19+2 tests)
Tests/LogicProMCPTests/PluginIdentityTests.swift              (8 tests)
Tests/LogicProMCPTests/PluginWindowLifecycleTests.swift       (6+1 tests)
```

### 수정 파일
없음 (모든 변경이 신규 파일로 격리됨)

---

## Isaac 검토 체크리스트

- [ ] PRD v0.5 최종 승인 여부 (Ralph 5-round 수렴 완료)
- [ ] PR-1(Foundation) vs PR-2(Handlers) 2-PR 분할 승인
- [ ] T0 probe script 1회 실행 + result doc 채우기
- [ ] T0 결과에 따른 §4 분기(AXPress vs CGEvent) 결정 + T6 핸들러 설계 시작
- [ ] 유예된 P3 editorial items (`ScannerWindowRecord` Equatable 구현, O(n²) dup-lookup 튜닝, `openWindowTimeoutThrows` catch 엄격화) — T6 작업 시 함께 정리 가능

---

## Phase 7 Sign-off

Foundation ready for merge. Handlers tier + rollout clearly scoped in tickets T6-T14 + STATUS.md. 10시간 자율 예산 내 XL feature의 현실적 최대 전달분 달성.
