# T9: AppleScript injection 수정 + Destructive Operation Policy

**PRD Ref**: PRD-logic-pro-mcp-v2 > US-6, §6.3, §6.4, §4.3.4
**Priority**: P1 (High)
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T7

---

## 1. Objective
AppleScript injection 근본 수정 (NSWorkspace.open + action whitelist). Destructive operation safety policy 구현 (L3 확인 플로우, 감사 로그).

## 2. Acceptance Criteria
- [ ] AC-1: project.open → NSWorkspace.shared.open(URL(fileURLWithPath:)) 사용. AppleScript 문자열 보간 0
- [ ] AC-2: transport action → whitelist ["play","stop","record","pause"] 외 reject
- [ ] AC-3: project.quit/close → L3 확인 응답 (§4.3.4 wire format)
- [ ] AC-4: confirmed: true 재호출 시 실제 실행
- [ ] AC-5: L1+ 명령 실행 시 감사 로그 (Log.info("[AUDIT]..."))
- [ ] AC-6: 특수문자 경로 (`"`, `\`, `\n`, `$`, `` ` ``) 안전 확인
- [ ] AC-7: save_as 경로 파라미터 → NSWorkspace 또는 화이트리스트 AS 템플릿. injection 차단
- [ ] AC-8: launch/quit/bounce → ProjectDispatcher의 직접 osascript 호출도 화이트리스트 패턴으로 통일

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testOpenProjectUsesNSWorkspace` | Unit | open 호출 | NSWorkspace.open 경로, AS 미사용 |
| 2 | `testOpenProjectSpecialChars` | Unit | 경로에 `"`, `\`, `$` | injection 없이 안전 |
| 3 | `testTransportWhitelist` | Unit | action "play" | 허용 |
| 4 | `testTransportRejectUnknown` | Unit | action "rm -rf" | reject |
| 5 | `testQuitRequiresConfirmation` | Unit | quit without confirmed | confirmation_required 응답 |
| 6 | `testQuitWithConfirmation` | Unit | quit with confirmed:true | 실제 실행 |
| 7 | `testCloseRequiresConfirmation` | Unit | close without confirmed | confirmation_required 응답 |
| 8 | `testSaveNoConfirmation` | Unit | save (L1) | 즉시 실행 |
| 9 | `testAuditLogOnSave` | Unit | save 실행 | "[AUDIT]" 로그 출력 |
| 10 | `testDestructiveLevelClassification` | Unit | 모든 command → level | L0-L3 올바르게 분류 |
| 11 | `testSaveAsPathInjection` | Unit | save_as 경로에 특수문자 | injection 없이 안전 |
| 12 | `testLaunchUsesWhitelist` | Unit | launch 명령 | 고정 AS 문자열만 사용 |
| 13 | `testBounceDestructiveLevel` | Unit | bounce | L2 분류 |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AppleScriptSecurityTests.swift`
- `Tests/LogicProMCPTests/DestructiveOperationTests.swift`

### 3.3 Mock/Setup Required
- MockNSWorkspace: open() 호출 캡처 (실제 Logic Pro 미실행 환경)
- Log capture: 감사 로그 출력 확인

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AppleScriptChannel.swift` | Modify | openProjectScript → NSWorkspace.open, action whitelist |
| `Sources/LogicProMCP/Dispatchers/ProjectDispatcher.swift` | Modify | L3 확인 플로우, 감사 로그, launch/quit 화이트리스트 패턴 |

### 4.2 Implementation Steps (Green Phase)
1. AppleScriptChannel: openProjectScript 제거 → NSWorkspace.shared.open(URL(fileURLWithPath:))
2. AppleScriptChannel: transportScript action whitelist + switch
3. ProjectDispatcher: destructiveLevel(for:) 함수 추가
4. ProjectDispatcher: L3 → confirmation_required JSON 응답
5. ProjectDispatcher: confirmed:true 파라미터 처리
6. ProjectDispatcher: L1+ 감사 로그

## 5. Edge Cases
- EC-1: 존재하지 않는 경로로 open (NSWorkspace 에러 핸들링)
- EC-2: Logic Pro 미실행 상태에서 quit (이미 처리됨)
- EC-3: confirmed 없이 반복 호출 (매번 confirmation_required)

## 6. Review Checklist
- [ ] Red → Green → Refactor
- [ ] AppleScript 문자열 보간 0건 (grep 확인)
- [ ] L3 wire format §4.3.4 일치
