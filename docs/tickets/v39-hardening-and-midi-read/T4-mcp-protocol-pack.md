# T4: MCP 프로토콜 팩 (PR-4)

**PRD Ref**: PRD-v39-hardening-and-midi-read > US-4
**Priority**: P1
**Size**: L
**Status**: Todo
**Depends On**: None (머지 순서상 T3 이후)
**Branch**: feat/v39-mcp-protocol

---

## 1. Objective
swift-sdk 0.12.1(확인 완료: outputSchema/structuredContent Tools.swift:22-23,405-420 · subscribe/updated Resources.swift:409-445 · prompts Server.swift:89-126)로 resource subscribe+updated 알림, prompts, 전 툴 structuredContent를 구현한다. SDK bump 없음.

## 2. Acceptance Criteria
- [ ] AC-1: resources capability `subscribe:true` + Subscribe/Unsubscribe 핸들러 + 세션 구독 레지스트리(actor). 서버/세션 종료 시 정리
- [ ] AC-2: 알림 diff 계약 — 리소스별 콘텐츠 해시(cache payload의 `data` 기준, `fetched_at`/`cache_age_sec` 등 휘발 필드 제외)로 변경 판정. StatePoller 폴 사이클 훅에서: 무변경 폴 = 무알림(테스트 필수), URI별 사이클당 최대 1회 coalescing, cache-key→URI 팬아웃 매핑 테이블 명시(예: tracks 캐시 → `logic://tracks` + 관련 template URI)
- [ ] AC-3: prompts capability — workflow-skills-pack의 기존 워크플로 데이터로 ListPrompts/GetPrompt 구현 (데이터 중복 정의 금지 — 기존 소스 재사용)
- [ ] AC-4: 전 10개 툴 structuredContent — dispatcher 경계 공용 wrap: 응답 text가 유효 JSON object면 동일 내용을 structuredContent로 병행. outputSchema: mutating 툴은 HC envelope 스키마(success/verified/state), read-성 툴은 generic object. 기존 text 하위호환 유지
- [ ] AC-5: 모든 알림 발행은 SerializedStdioTransport 경유 — 동시 대량 쓰기 프레임 원자성 회귀 테스트(#220 계열) 추가
- [ ] AC-6: 런타임 프로브 통합 테스트 — **in-process TestTransport 하니스 신설**(independent review#3: Swift 테스트에 stdio probe 부재. SDK `Transport` 프로토콜 구현체로 JSON-RPC 프레임 주입/캡처, mock runtime으로 폴러 변경 트리거): initialize→subscribe→변경→updated 프레임 수신, prompts/list+get, tools/call structuredContent 확인. 실 stdio 검증은 `Scripts/live-e2e-test.py`에 케이스 추가로 보완

## 3. TDD Spec (Red Phase)

| # | Test Name | Type | Expected (Red) |
|---|-----------|------|----------------|
| 1 | `subscription_registry_add_remove_cleanup` | Unit | FAIL (레지스트리 부재) |
| 2 | `unchanged_poll_emits_no_notification` | Unit | FAIL |
| 3 | `changed_payload_emits_single_coalesced_notification` | Unit | FAIL |
| 4 | `volatile_fields_excluded_from_change_hash` | Unit | FAIL |
| 5 | `prompts_list_and_get_roundtrip` | Integration(probe) | FAIL |
| 6 | `tools_call_includes_structured_content_all_tools` | Integration(probe) | FAIL |
| 7 | `notifications_do_not_corrupt_concurrent_frames` | Regression | FAIL/신규 |
| 8 | `capabilities_advertise_subscribe_and_prompts` | Integration | FAIL |

### Test File Location
- `Tests/LogicProMCPTests/ResourceSubscriptionTests.swift`, `PromptsTests.swift`, `StructuredContentTests.swift` (신규) + 기존 probe 테스트 파일 패턴 참조

### SDK API 확정 (spike 매트릭스, 재조사 불필요)
- capabilities: `Server.Capabilities(prompts: .init(listChanged:), resources: .init(subscribe: true, …))` — 현재 등록부 LogicProServer.swift:261, 툴 위임 :827
- subscribe: `withMethodHandler(ResourceSubscribe.self)` / `ResourceUnsubscribe.self` (Resources.swift:411,423) — 구독 상태는 자체 actor 보관(SDK에 레지스트리 없음, conformance 서버도 수동 Set)
- 알림: `server.notify(ResourceUpdatedNotification.message(.init(uri:)))` (Server.swift:378) — SerializedStdioTransport(:78) serial queue로 프레임 원자성 확보됨
- prompts: `withMethodHandler(ListPrompts.self)`/`GetPrompt.self`, `ListPrompts.Result`/`GetPrompt.Result` (Prompts.swift:11-377)
- structured: `Tool(..., outputSchema: Value?)` + `CallTool.Result(content:, structuredContent: Value?)` (Tools.swift:22,405-451)
- listChanged: 우리 툴/리소스 목록은 정적 — `listChanged`는 false 유지 (범위 외)

### 주의
- SDK API는 위 확정 시그니처 사용 — 상상 API 금지, 컴파일로 검증
- dead-#expect 금지. actor 격리 하 Swift 6 concurrency 준수 (기존 코드 스타일)
- 알림 발행 실패는 warn 로그 후 무해화 (서버 다운 금지)

## 4. Implementation Guide

| File | Change |
|------|--------|
| Sources/LogicProMCP/Server/LogicProServer.swift | capabilities + 핸들러 등록 |
| Sources/LogicProMCP/Server/ResourceSubscriptions.swift (신규) | 레지스트리 actor + diff 해시 |
| Sources/LogicProMCP/State/StatePoller.swift | 폴 사이클 변경 훅 (최소 침습) |
| Sources/LogicProMCP/Server/Prompts*.swift (신규) | prompts 핸들러 |
| Sources/LogicProMCP/Utilities/MCPToolContent.swift | structuredContent wrap + outputSchema |
| Tests/… | 위 테스트 |
| docs/API.md, CHANGELOG.md | capability 문서화 (additive) |

검증: `swift test --no-parallel`.

## 5. Edge Cases (PRD E6/E7)
- EC-1: 구독 클라이언트 무응답 종료 → 세션 정리, 발행 실패 무해화
- EC-2: 알림·툴응답 동시 발행 → 프레임 원자성
- EC-3: 미존재 URI subscribe → 프로토콜 에러(-32602 계열, 기존 boundary 관례)

## 6. Review Checklist
- [ ] Red FAILED → Green PASSED → Refactor 유지
- [ ] Package.resolved 무변경 (SDK bump 없음 확인)
- [ ] AC 전부 / 기존 테스트 무파손 / 하위호환(text) 유지
