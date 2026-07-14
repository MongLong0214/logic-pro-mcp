# PRD: v3.9 Hardening & MIDI Read Path

**Version**: 0.2 (independent review r1 반영: P1×7/P2×5 전건 수용)
**Author**: Product planning
**Date**: 2026-07-06
**Status**: Approved (Phase 2 수렴: r1 12건 반영, r2 11/12 RESOLVED, 잔여 1건 r2' PASS)
**Size**: XL

> 실행 모델: 모든 코드 변경은 문서화된 검토 및 검증 게이트를 따른다.

---

## 1. Problem Statement

### 1.1 Background
2026-06-08/09 전수 리뷰 리포트의 잔여 findings 재검증(2026-07-06) 결과: 대부분 v3.5~v3.8에서 해소됐으나 (a) 릴리스 파이프라인 무결성 갭 4건, (b) HC 전역화 마지막 잔여(CoreMIDI 성공 응답 평문 ~12곳), (c) MIDIPortManager mode-blind 캐시가 아직 열려 있다. 별도로 기능 표면 공백 스카우팅 결과: MIDI 콘텐츠 **읽기** 경로 전무(쓰기 전용), MCP 프로토콜 기능 미사용(subscribe/prompts/structuredContent), 검증 가능 플러그인 파라미터가 Compressor threshold 1개뿐.

### 1.2 Problem Definition
릴리스 무결성·계약 정직성의 마지막 균열을 닫고, 북극성("자연어로 Logic 100% 컨트롤")을 막는 최대 병목인 MIDI 읽기 부재를 해소한다.

### 1.3 Impact of Not Solving
- 테스트 안 거친 tag가 그대로 배포될 수 있음(release.yml에 test 게이트 없음 — v3.7.2에서 실제로 당한 계열).
- `versionReleaseTimestamp`가 이미 v3.8.0과 어긋난 채 배포 중(리소스 lastModified 거짓).
- logic_midi 성공 응답이 README의 "모든 mutating op는 HC" 문장과 모순.
- 노트를 읽지 못하면 "멜로디 옮겨줘"류 자연어 편집이 원천 불가.

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] G1: tag-push 릴리스가 `swift test --no-parallel` 통과 없이는 패키징 불가 (WS1)
- [ ] G2: `Package.resolved` drift가 CI에서 fail-loud (WS1)
- [ ] G3: `versionReleaseTimestamp`·버전 표면이 CHANGELOG 최신 릴리스와 테스트로 결박 (WS1)
- [ ] G4: 모든 mutating route가 HC JSON envelope 반환 + ratchet invariant 테스트로 영구 고정 (WS2)
- [ ] G5: MIDIPortManager cross-mode 요청이 fail-closed conflict 에러 (WS3)
- [ ] G6: swift-sdk 0.12.1이 지원하는 범위 내에서 resource subscribe/updated 알림 + prompts + structuredContent 노출 (WS4)
- [ ] G7: 선택 region의 노트 데이터를 JSON으로 읽는 공개 커맨드 제공 + `record_sequence` 노트 레벨 검증(opt-in) (WS5)
- [ ] G8: Channel EQ 파라미터가 verified param registry에 등재되어 `set_param_verified`로 검증 write 가능 (WS6)
- [ ] G9: `feature/verified-plugin-applyback` 브랜치 처분 완료 (D-1, 삭제 승인됨)

### 2.2 Non-Goals
- NG1: automation 커브/브레이크포인트 write (검증 경로 미증명 — 별도 epic)
- NG2: mixer sends/routing/EQ 라우팅 ops 해금 (refused 정책 유지)
- NG3: swift-sdk major 버전 점프 (minor 범위 내 bump만 허용, 그 이상은 에스컬레이션)
- NG4: `logic://…/notes` **리소스** 노출 — 노트 읽기는 AX 구동(선택 변경+다이얼로그)이 필요하므로 read-only 리소스 계약 위반. 툴 커맨드로만 노출한다.
- NG5: `set_cycle_range` 검증 write 재도전 (Logic 12.x 표면 부재 — 기존 honest State C 유지)
- NG6: rename_marker 구현 확정 — 라이브 스파이크로 가능성만 판정, 실패 시 honest defer 유지

## 3. User Stories & Acceptance Criteria

### US-1 (WS1): 릴리스 무결성 팩
**As a** maintainer, **I want** 릴리스 파이프라인이 테스트/브랜치/의존성/버전 표면을 fail-closed로 게이트하기를, **so that** 검증 안 된 코드가 버전 이름을 달고 나가지 않는다.

**AC:**
- [ ] AC-1.1: release.yml build job에서 packaging **이전에** `swift test --no-parallel` 실행, 실패 시 job fail
- [ ] AC-1.2: `Scripts/release.sh`가 (a) branch≠main 또는 HEAD≠origin/main이면 즉시 종료(release-stable.sh:53,66 동일), (b) tag push/GH release **이전에** `swift test --no-parallel` + `git diff --exit-code Package.resolved`를 자체 실행 — release.sh 단독 경로로도 미검증 발행 불가 (independent review#1)
- [ ] AC-1.3: ci.yml에 `git diff --exit-code Package.resolved` 스텝 — resolve 후 lockfile 변동 시 fail
- [ ] AC-1.4: timestamp SSOT = **CHANGELOG 최신 릴리스 헤딩의 UTC 날짜** (independent review#12). VersionConsistencyTests가 (a) 리소스가 실제로 노출하는 lastModified annotation == SSOT (private static 직접 비교 금지 — 공개 표면 기준), (b) README 버전 배지/참조 == `ServerConfig.serverVersion` 검증. 현재 stale 값(2026-06-23→2026-07-05) 수정 포함
- [ ] AC-1.5: 기존 release/tag 흐름의 다른 스텝은 무변경 (behavior-preserving 외 추가 게이트만)

### US-2 (WS2): HC 전역화 마감
**As an** MCP client, **I want** 모든 mutating 커맨드 응답이 HC State A/B/C JSON이기를, **so that** verified/reason 필드를 전역 계약으로 신뢰할 수 있다.

**AC:**
- [ ] AC-2.1: **shape 변경 대상 전수 명시** (independent review#2): logic_midi mutating 커맨드 전부 — CoreMIDI 라우트(send_note/chord/cc/program_change/pitch_bend/aftertouch/sysex, mmc_play/stop/record/locate, play_sequence, step_input, create_virtual_port)와 **keycmd 라우트 포함**. 권위 목록은 RoutingTable의 `midi.*` mutating 세트에서 도출하고 T2 티켓+테스트로 고정. 제외(read-only, shape 불변): list_ports. import_file은 기존 HC 유지. 성공 응답은 State B(`reason:"send_only_no_readback"` 계열), 기존 정보(bytes 수 등)는 extras 보존
- [ ] AC-2.2: 전역 HC invariant 테스트 — RoutingTable의 mutating op 전수를 순회하며 채널 응답이 HC JSON(schema: success/verified/state 필수 키)으로 파싱됨을 검증. 라이브 전용 op는 **명시 allowlist**로 skip하되, allowlist는 축소만 가능(ratchet: 크기 상한 고정 테스트)
- [ ] AC-2.3: `Scripts/live-e2e-test.py`가 새 logic_midi 응답 shape를 검증하도록 갱신 (구 평문 핀 제거)
- [ ] AC-2.4: CHANGELOG에 BREAKING(logic_midi 응답 shape 변경) 명시

### US-3 (WS3): 소형 수정 팩
**AC:**
- [ ] AC-3.1: MIDIPortManager — 같은 name·**같은 mode**는 기존대로 재사용(MCU restart가 bidirectional 재사용에 의존, LogicProServer.swift:1008-1018 — independent review#9), 같은 name·**다른 mode**는 명시적 `modeConflict` 에러로 fail-closed. cross-mode 테스트 2방향 + **restart 재사용 회귀 테스트** 추가
- [ ] AC-3.2: `transport.toggle_autopunch` 신규 커맨드 — **AX 컨트롤바 Autopunch 버튼 우선**(버튼 상태 readback 가능 → State A), AX 미발견 시 honest State C `not_implemented`. keycmd 경로는 채택하지 않음(.logikcs 갱신은 자율 불가 — 에스컬레이션 대상이므로)
- [ ] AC-3.3: `track.set_automation`이 docs/API.md tracks 커맨드 목록에 State B 시맨틱스와 함께 문서화
- [ ] AC-3.4: help 텍스트/routing invariant 테스트가 신규 커맨드와 정합

### US-4 (WS4): MCP 프로토콜 팩
**As a** Claude Desktop/Code user, **I want** 서버가 MCP 네이티브 알림·prompts·구조화 출력을 지원하기를, **so that** 폴링 없이 상태 변화를 받고 워크플로를 슬래시로 쓴다.

**AC:** (SDK 0.12.1 지원 **확인됨** — outputSchema/structuredContent: swift-sdk `Sources/MCP/Server/Tools.swift:22-23,405-420`, subscribe/updated: `Resources.swift:409-445`, prompts: `Server.swift:89-126`. independent review#10 반영: "지원 시" 조건절 제거, spike는 런타임 프로브 검증으로 축소)
- [ ] AC-4.1: T-spike(축소) — JSON-RPC stdio 프로브로 subscribe→updated 수신, prompts/list·get, structuredContent 왕복을 런타임 검증하는 통합 테스트. SDK bump 불필요 확인(0.12.1 그대로)
- [ ] AC-4.2: resources capability `subscribe:true` + **알림 diff 계약** (independent review#4): 리소스별 콘텐츠 해시(payload data 기준, fetched_at/age 등 휘발 필드 제외)로 변경 판정 — 무변경 폴은 무알림(테스트 필수), 폴 사이클당 URI별 최대 1회 coalescing, cache-key→URI 팬아웃 매핑 명시, 세션별 구독 레지스트리 + 종료 시 정리
- [ ] AC-4.3: prompts capability — workflow-skills-pack의 기존 워크플로를 MCP prompt로 노출 (ListPrompts/GetPrompt)
- [ ] AC-4.4: **전 10개 툴 일괄** (independent review#3, OQ-1 해소): dispatcher 경계에서 응답 text가 유효 JSON object면 동일 내용을 structuredContent로 병행 발행. outputSchema는 툴별 선언 — mutating 툴은 HC envelope 스키마(success/verified/state 필수), read-성 툴은 generic object 스키마. 기존 JSON-in-text 하위호환 유지
- [ ] AC-4.5: 알림 발행이 SerializedStdioTransport 경유로 프레임 원자성 유지 (동시쓰기 corruption 회귀 방지 테스트)

### US-5 (WS5): MIDI 읽기 경로
**As a** natural-language user, **I want** 선택 region의 노트를 JSON으로 읽기를, **so that** 읽기→편집→쓰기 루프가 가능하다.

**AC:** — **T0 게이트 결과 2026-07-07: FAILED → AC-5.3/5.4/5.5(라이브 표면) honest-deferred. AC-5.2(SMFReader)+임시파일 매니저만 T5a로 출하.** 상세 증거: `docs/spikes/midi-export-t0-evidence.md`.
- [x] AC-5.1 (게이트, **FAILED**): 라이브 스파이크로 File>Export>Selection as MIDI File 메뉴 도달·record_sequence sentinel·region 열거까지는 성공했으나, export **저장 패널이 out-of-process remote-view**라 (a) 내부 컨트롤 AX-불투명, (b) 합성 키보드 입력 미도달(Secure Input OFF 확인, osascript/cliclick/focus-click 3채널 검증), (c) 마우스만으로는 통제 디렉토리+파일명 입력 불가 → 통제-저장 계약 충족 불가. 자동화 시도가 Logic을 modal-stack hang으로 유발(force-quit 복구). 이 repo가 반복 honest-defer해온 라이브-UI 월과 동일 계열.
- [ ] AC-5.2: `SMFReader` — format 0/1, tempo/time-sig meta, note on/off 페어링, division 기반 tick→bar/beat 변환. **필수 fixture** (independent review#8): running status, velocity-0 note-off, 동일 pitch/channel 중첩 노트, SMPTE division 거부, VLQ/track-length 경계, format-1 멀티트랙 tempo 병합, channel 1-based 출력. malformed SMF는 fail-closed(부분 결과 반환 금지)
- [~] AC-5.3 (**DEFERRED**, T0 실패): `logic_midi.read_selection_notes` — **State A 조건 강화** (independent review#5): (a) export 파일이 신규 생성(사전 부재+mtime/size 검증), (b) 파싱 성공, (c) export 직전 AX로 선택 identity(region/track) 캡처 후 evidence에 포함. identity 캡처 불가 시 State B. 임시 파일은 **전용 export 레지스트리 매니저** (independent review#7: SMFWriter+TemporaryFiles 대칭 — 전용 디렉토리 생성, symlink escape 방지, 파싱 후 cleanup, 테스트 포함) 경유
- [~] AC-5.4 (**DEFERRED**, T0 실패): `record_sequence verify_notes:true` (independent review#6 강화) — (a) 기존 선택/플레이헤드 캡처, (b) **생성된 region을 결정론적으로 선택**(기존 region-enumeration 결과의 identity 사용), 선택 검증 실패 시 export 시도 없이 State B, (c) export→파싱→요청 노트 대조 일치 시 State A(노트 evidence), (d) 이전 선택 복원. 기본값 false
- [~] AC-5.5 (**DEFERRED**, T0 실패): 선택이 없거나 MIDI region이 아닐 때 명시적 typed 에러(State C), 다이얼로그 잔류 없음(Escape 폴백)

### US-6 (WS6): Channel EQ verified 파라미터 확장
**AC:**
- [ ] AC-6.1: 라이브 census 스파이크 (independent review#11 강화) — **census artifact 문서** 산출: 파라미터별 canonical ID, AX role/description, 단위·범위·tolerance(dB/Hz/Q), 밴드 enable 동작, 플러그인 에디터 창 전제조건, 라이브 E2E 케이스 정의. 이 artifact가 registry 등재의 유일 근거
- [ ] AC-6.2: verified param registry(기존 `StockPluginParameterMetadata`/`VerifiedPluginCatalog` 패턴 확장, 신규 타입 금지)에 census 증명 파라미터 등재(최소: 1개 밴드 gain+freq). 단위별 readback tolerance 정의
- [ ] AC-6.3: 미등재 파라미터는 기존과 동일하게 `unsupported_param_readback` fail-closed 유지
- [x] AC-6.4: **완료(2026-07-06)** — applyback 델타 리포트 결과 unique 커밋 0(PR #24로 기머지), 흡수 대상 없음, origin/로컬 브랜치 삭제 완료
- [ ] AC-6.5: 라이브 E2E에 Channel EQ verified write 1케이스 추가
- [ ] AC-6.6: rename_marker 라이브 스파이크(WS6 라이브 세션 편승) — 마커 리스트 AX 텍스트 편집 가능성 판정. PASS 시 verified rename 구현(State A, 별도 보정 티켓), FAIL 시 기존 honest State C 유지 + 증거 문서화

## 4. Technical Design

### 4.1 Architecture Overview
기존 아키텍처(dispatcher → ChannelRouter → channels / ResourceHandlers → StateCache) 불변. 신규 컴포넌트:
- `SMFReader` (MIDI/): SMFWriter 대칭 파서
- 구독 레지스트리 (Server/): 세션별 subscribed URI set + StatePoller 변경 훅
- prompts 핸들러 (Server/): workflow-skills-pack 데이터 재사용
- verified param registry 엔트리 (기존 registry 확장, 신규 타입 없음)

### 4.2 Data Model Changes
없음 (프로젝트 파일/DB 무접촉). SMF 임시 파일은 통제 디렉토리 내 생성 후 삭제.

### 4.3 API Design (MCP surface)

| Surface | Change | Shape |
|---------|--------|-------|
| `logic_midi` 전 커맨드 응답 | **BREAKING**: 평문 → HC State B envelope | `{success, verified:false, state:"B", reason, extras}` |
| `logic_midi.read_selection_notes` | 신규 | State A envelope + `notes:[{pitch,velocity,start_bar,start_beat,duration_beats,channel}]` |
| `logic_tracks.record_sequence` | `verify_notes` opt-in 파라미터 추가 (기본 false — 하위호환) | State A(노트 evidence) / State B(사유) |
| `logic_transport.toggle_autopunch` | 신규 | State A(AX 버튼 readback) / State C |
| `logic_plugins.set_param_verified` | 지원 파라미터 확장 (shape 불변) | 기존 계약 |
| resources capability | `subscribe: true` (+updated 알림) | MCP 표준 |
| prompts capability | 신규 | MCP 표준 |
| tool results | structuredContent 추가 (text 병행 — 하위호환) | MCP 표준 |

### 4.4 Key Technical Decisions

| Decision | Options | Chosen | Rationale |
|----------|---------|--------|-----------|
| release 테스트 게이트 방식 | 워크플로 내 직접 실행 vs tag SHA의 CI 성공 조회 | 직접 실행 | 자기완결, checks-API 레이스 없음. CoreMIDI -50 skip 기존 처리 재사용 |
| timestamp 진실원 | 하드코딩 유지 / GitHub API / CHANGELOG 파싱 | CHANGELOG 최신 릴리스 헤딩 | 리포 내 결정론적 단일 진실. 테스트가 빌드타임에 검증 가능 |
| CoreMIDI 성공 State | A로 위장 / B / 평문 유지 | State B (`send_only_no_readback`) | send-only MIDI는 readback 불가 — 정직한 최대치 |
| HC invariant 커버리지 | 전 op 강제 / allowlist skip | ratchet allowlist | 라이브 전용 op 존재. allowlist 축소-only 상한 테스트로 후퇴 방지 |
| MIDIPort mode 충돌 | (name,mode) 이중 생성 / conflict 에러 | conflict 에러 | 동일 이름 중복 가상 엔드포인트는 Logic에서 혼동 유발. fail-closed가 리포 ethos |
| autopunch 경로 | keycmd / AX 버튼 / CGEvent | AX 버튼 | keycmd는 .logikcs 갱신 필요(자율 불가). AX 버튼은 상태 readback → State A 가능 |
| 노트 읽기 노출 | 리소스 / 툴 커맨드 | 툴 커맨드만 | export는 AX 구동 side-effect — read-only 리소스 계약 위반 (NG4) |
| record_sequence 검증 | 기본 on / opt-in | opt-in `verify_notes` | export 왕복은 지연+선택상태 변경+다이얼로그 리스크. 기본 동작 보존 |
| SDK 갭 처리 | fork / major bump / defer | **bump 불필요 — 0.12.1 전 기능 지원 확인** | independent review#10: Tools.swift/Resources.swift/Server.swift 증거 |
| structuredContent 적용 범위 | 일부 툴 / 전 툴 | 전 10개 툴 일괄 (dispatcher 경계 wrap) | independent review#3: 부분 적용은 계약 파편화. text JSON 미러링이라 증분 비용 균일 |
| 알림 변경 판정 | 타임스탬프 / 콘텐츠 해시 | 휘발 필드 제외 콘텐츠 해시 | independent review#4: fetched_at 갱신만으로 오알림 방지, 무변경 폴=무알림 테스트 가능 |
| release.sh 발행 권한 | Actions 위임 / 자체 게이트 | 자체 게이트(test+lockfile+branch) 추가 | independent review#1: 스크립트 단독 경로도 fail-closed. Actions 위임은 흐름 재설계라 과대수술 |

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | release.yml 테스트가 CI 러너 CoreMIDI -50 | 기존 explicit skip 경로로 green (v3.4.4 학습) | High |
| E2 | Package.resolved가 로컬만 갱신된 채 커밋 누락 | CI drift 게이트 fail | Med |
| E3 | export 다이얼로그가 예상 외 시트/경고 표시 | Escape 폴백 + State C, 다이얼로그 잔류 금지 | High |
| E4 | SMF에 note-off 누락(달린 노트) | 페어링 실패 노트는 명시 에러 — 부분 결과 반환 금지 | High |
| E5 | 빈 선택/오디오 region에서 read_selection_notes | typed State C (`no_midi_selection`) | Med |
| E6 | 구독 클라이언트가 응답 없이 종료 | 세션 종료 시 구독 정리, 알림 발행 실패 무해화 | Med |
| E7 | 알림과 툴 응답 동시 발행 | SerializedStdioTransport 원자성 (기존 #220 수정 재사용) | High |
| E8 | Channel EQ 미설치 상태(불가능하지만)/에디터 미오픈 | 기존 insert_verified 선행 경로 재사용, 실패 시 State C | Med |
| E9 | verify_notes에서 export 노트 수 == 0 | State B `export_empty` — 성공 위장 금지 | High |
| E10 | Autopunch 버튼이 컨트롤바 커스터마이즈로 숨김 | State C `ax_element_not_found` + remediation 힌트 | Med |

## 6. Security & Permissions

### 6.1/6.2 Authentication/Authorization
N/A (로컬 stdio MCP, 기존 TCC 모델 불변).

### 6.3 Data Protection
- export 임시 SMF는 통제 디렉토리(`/tmp/LogicProMCP/` 계열) 한정, symlink escape 검사(import_file 게이트 재사용), 파싱 후 즉시 삭제.
- 노트 JSON에 프로젝트 경로/파일명 미포함(트랙 인덱스/region 인덱스만).
- prompts/알림에 로컬 경로 누출 금지(doctor v3 redaction 관례 준수).

## 7. Performance & Monitoring

| Metric | Target | Measurement |
|--------|--------|-------------|
| release job 증가 시간 | +≤15min (테스트 스텝) | Actions run 시간 |
| read_selection_notes 왕복 | ≤10s (AX 다이얼로그 포함) | 라이브 E2E 타이밍 |
| updated 알림 지연 | 폴러 주기 +≤1s | 유닛(mock clock) |
| record_sequence 기본 경로 | 기존 대비 무변화 (verify_notes=false) | 회귀 벤치 불요, 코드 경로 분리로 보장 |

### 7.1 Monitoring
기존 Log 채널 사용. 알림 발행 실패는 warn 로그(전송 corruption 방지 우선).

## 8. Testing Strategy

### 8.1 Unit
- SMFReader: golden SMF fixtures(WriterA산출물 round-trip + 수작업 malformed), tick→bar 변환, tempo map
- HC invariant: RoutingTable 전수 순회 + ratchet allowlist 상한
- MIDIPortManager cross-mode 2방향
- 구독 레지스트리: subscribe/unsubscribe/세션 정리/변경→알림 매핑
- VersionConsistency 확장: CHANGELOG 파싱 결박
- CoreMIDI State B: 커맨드별 envelope shape

### 8.2 Integration
- record_sequence verify_notes: mock AX + 실제 SMFWriter→SMFReader round-trip
- prompts/structuredContent: 프로토콜 레벨 JSON-RPC probe 테스트(기존 MainEntrypoint 패턴)

### 8.3 Edge (Section 5 전수)
E1~E10 각 1개 이상 테스트 매핑. 라이브 전용(E3, E10)은 strict 라이브 E2E에 추가.

## 9. Rollout Plan

### 9.1 Migration
없음. BREAKING은 응답 shape뿐 — CHANGELOG + docs/API.md 갱신.

### 9.2 순서 (PR 단위 순차 머지, 각각 CI green + 필요 시 라이브 E2E)
PR-1(release-integrity) → PR-2(hc-globalization) → PR-3(small-fixes) → PR-4(mcp-protocol-pack) → PR-5(midi-read-path) → PR-6(param-registry-eq) → (선택) v3.9.0 릴리스 안무 재사용.

### 9.3 Rollback
PR 단위 revert 가능하도록 각 PR 자기완결. WS5/6는 라이브 게이트 실패 시 해당 PR 자체를 defer(부분 출하 금지).

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if Delayed |
|-----------|-------|--------|-----------------|
| swift-sdk 0.12.1 기능 범위 | independent review r1 검증 | **확인됨(전 기능 지원)** | 없음 — spike는 런타임 프로브로 축소 |
| Logic Pro 12.3 라이브 세션 | Isaac Mac (자율 승인됨) | 가용 | WS5/6 defer |
| Export 메뉴 locale/12.3 구조 | T0 스파이크 | 미확인 | WS5 전체 defer |
| Channel EQ AX-settable census | 라이브 스파이크 | 미확인 | WS6 축소/defer |

### 10.2 Risks
| Risk | Prob | Impact | Mitigation |
|------|------|--------|------------|
| export save 다이얼로그 자동화 실패 | Med | WS5 defer | T0 게이트 선행, Escape 폴백, honest defer 관례 |
| logic_midi shape 변경이 외부 사용자 破壊 | Med | 불만/이슈 | BREAKING 명시 + State B extras에 기존 메시지 보존 |
| release.yml 테스트가 러너에서 flaky | Low | 릴리스 지연 | --no-parallel(CI 관례) + CoreMIDI skip 기존 처리 |
| SDK subscribe/prompts/structuredContent 런타임 동작이 문서와 상이 | Low | WS4 일부 조정 | 런타임 프로브 통합테스트(AC-4.1)가 선행 검증 |
| 알림 발행이 stdio 오염 | Low | 프로토콜 파손 | SerializedStdioTransport 경유 강제 + 회귀 테스트 |

## 11. Success Metrics

| Metric | Baseline | Target | Method |
|--------|----------|--------|--------|
| 테스트 없이 배포 가능한 경로 | 1 (tag push) | 0 | release.yml 검사 |
| HC 미준수 mutating op | ~12 | 0 (+ratchet) | invariant 테스트 |
| 노트 읽기 커맨드 | 0 | 1 (State A) | 라이브 E2E |
| verified 파라미터 수 | 1 | ≥3 | registry census |
| 클라이언트 폴링 필요 리소스 | 전부 | 구독 가능 | capability 검사 |

## 12. Open Questions
- [x] OQ-1: 해소(v0.2) — 전 10개 툴 일괄 적용 (4.4 결정표 참조)
- [ ] OQ-2: v3.9.0 릴리스를 PR-6 직후 바로 수행할지 — Phase 7 보고 시 Isaac 결정
