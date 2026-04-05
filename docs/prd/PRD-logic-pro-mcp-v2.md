# PRD: Logic Pro MCP Server v2 — Production-Grade 95% Control

**Version**: 0.6
**Author**: Isaac (MongLong0214)
**Date**: 2026-04-05
**Status**: Approved
**Size**: XL
**Base**: Original implementation, MIT License
**Minimum Logic Pro Version**: 12.0.1 (Build 6590) — 개발/테스트 기준 버전

---

## 1. Problem Statement

### 1.1 Background
Logic Pro는 macOS의 대표 DAW이지만 공개 API가 없어 외부 프로그래밍 제어가 극히 제한적이다. 초기 프로토타입은 5개 macOS 채널(CoreMIDI, Accessibility, CGEvent, AppleScript, OSC)로 MCP 서버를 구현했으나, 코드 리뷰 결과 다수의 Critical 이슈가 발견되었다:

- OSC 채널이 믹서 primary인데 Logic Pro가 OSC를 네이티브 지원하지 않음
- Accessibility 트리 탐색이 미검증 추측 기반
- CoreMIDI ↔ Dispatcher 간 operation key 불일치
- AppleScript command injection 취약점
- 테스트 0개
- StatePoller가 transport 외 항목 미폴링

리서치를 통해 **Mackie Control Universal(MCU) 프로토콜**, **MIDI Key Commands**, **Scripter MIDI FX 브릿지**라는 3개의 추가 제어 채널을 발견했다. 특히 MCU는 Logic Pro가 네이티브로 완벽 지원하는 양방향 프로토콜로, 믹서/플러그인/센드/EQ/오토메이션 제어와 **상태 피드백 읽기**를 모두 해결한다.

### 1.2 Problem Definition
기존 Logic Pro MCP 서버가 광고하는 기능의 30-40%만 실제 작동하며, 음악 제작 워크플로우에 실용적으로 사용할 수 없다.

### 1.3 Impact of Not Solving
AI 어시스턴트를 통한 Logic Pro 제어가 불가능하여, 모든 DAW 조작을 수동으로 수행해야 한다. 반복적인 믹싱 작업, 트랙 관리, 플러그인 파라미터 조정 등에서 생산성 손실이 발생한다.

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] G1: Logic Pro 제어 커버리지 기존 30-40% → **93-95%** 달성 (측정: Appendix A 기능 체크리스트 항목 수 / 총 항목 수)
- [ ] G2: MCU 프로토콜 기반 양방향 믹서 제어 + 상태 피드백 구현
- [ ] G3: MIDI Key Commands 채널로 Logic Pro의 모든 키보드 단축키를 MIDI로 트리거
- [ ] G4: Scripter MIDI FX 브릿지로 플러그인 파라미터 딥 컨트롤 (Phase 0 실측 결과에 따라 scope 조정)
- [ ] G5: 모든 채널에 대한 unit test 작성 (coverage > 70%)
- [ ] G6: 보안 취약점 0개 (AppleScript injection 등 수정)
- [ ] G7: 1명 개인 사용 환경에서 24시간 연속 구동 crash 0회, 세션당 에러율 < 1%

### 2.2 Non-Goals
- NG1: Logic Remote 프로토콜(MultipeerConnectivity) 리버스엔지니어링 — 비공개 프로토콜, 변경 위험 높음
- NG2: 오디오 파형 직접 편집 (Flex, Fade 드래그) — 마우스 드래그 전용, API 없음
- NG3: 서드파티 플러그인 GUI 내부 위젯 조작 — AX 미노출
- NG4: Live Loops 그리드 직접 조작 — Logic Remote 전용
- NG5: 스코어 에디터 음표 직접 배치 — GUI 전용
- NG6: 멀티유저/원격 접속 지원 — 개인 로컬 사용만
- NG7: npm/PyPI 등 패키지 매니저 배포 — 바이너리 빌드 + claude mcp add 등록

## 3. User Stories & Acceptance Criteria

### US-1: 믹서 제어 (MCU)
**As a** 음악 프로듀서, **I want** AI 어시스턴트에게 "보컬 트랙 볼륨 -3dB, 패닝을 왼쪽 30%로"라고 말하면 Logic Pro 믹서가 조정되는 것, **so that** 마우스 없이 믹싱할 수 있다.

**Acceptance Criteria:**
- [ ] AC-1.1: Given MCU 연결 상태, when `logic_mixer("set_volume", {track: 2, value: 0.7})` 호출, then Logic Pro 채널 2의 페이더가 70% 위치로 이동하고 MCU 피드백으로 확인
- [ ] AC-1.2: Given MCU 연결 상태, when `logic_mixer("set_pan", {track: 2, value: -0.3})` 호출, then Logic Pro 채널 2의 팬이 L30으로 이동 (value: -1.0~+1.0, 기존 계약 유지)
- [ ] AC-1.3: Given MCU 연결 상태, when Logic Pro에서 수동으로 페이더 이동, then MCP 리소스 `logic://mixer`에 변경된 값이 반영 (양방향)
- [ ] AC-1.4: Given 8개 초과 트랙, when `logic_mixer("set_volume", {track: 12, value: 0.5})`, then 뱅킹 트랜잭션(bank→execute→restore)이 atomic하게 실행되어 해당 트랙 제어
- [ ] AC-1.5: Given MCU 미연결, when mixer 명령 호출, then `{error: "MCU not connected", guide: "..."}` 에러 반환 + `logic_system("health")`에서 MCU 미등록 상태 표시
- [ ] AC-1.6: Given MCU 연결 상태, when `logic_mixer("set_send", {track: 1, bus: 0, value: 0.5})` 호출, then 트랙 1의 Send 1 레벨 50% 설정 (bus: 기존 파라미터명 유지)

### US-2: 플러그인 파라미터 제어 (MCU + Scripter)
**As a** 음악 프로듀서, **I want** "EQ에서 2kHz를 3dB 부스트해줘"라고 말하면 플러그인이 조정되는 것, **so that** 플러그인 UI를 열지 않고 사운드를 조정할 수 있다.

**Acceptance Criteria:**
- [ ] AC-2.1: Given MCU 플러그인 모드, when `logic_mixer("set_plugin_param", {track: 1, insert: 0, param: 3, value: 0.65})` 호출, then Logic Pro 트랙 1의 첫 번째 인서트 슬롯의 파라미터 3이 변경
- [ ] AC-2.2: Given Scripter 브릿지 설치됨, when MIDI CC 102-119 전송, then 해당 채널 스트립의 타겟 플러그인 파라미터 1-18이 변경 (§4.7 매핑 규칙)
- [ ] AC-2.3: Given MCU 피드백, when 플러그인 모드 진입, then `logic://mixer` 리소스에 현재 인서트 슬롯 + 파라미터 이름/값 노출

### US-3: Transport 제어
**As a** 음악 프로듀서, **I want** "재생", "녹음", "120BPM으로 템포 변경"이 즉시 실행되는 것, **so that** 키보드에서 손을 떼지 않고 작업할 수 있다.

**Acceptance Criteria:**
- [ ] AC-3.1: Given Logic Pro 실행 중, when `logic_transport("play")` 호출, then MCU command 전송 후 50ms 이내에 MCU play feedback 수신
- [ ] AC-3.2: Given 재생 중, when `logic_transport("stop")` 호출, then 재생 정지
- [ ] AC-3.3: Given MIDI Key Commands 프리셋 설치, when `logic_transport("set_tempo", {bpm: 120})` 호출, then MIDIKeyCommands 채널로 "Set Tempo" 키커맨드 트리거 (MCU에 네이티브 tempo set 없음)
- [ ] AC-3.4: Given MCU 피드백, when transport 상태 변경, then `logic://transport/state` 리소스에 실시간 반영

### US-4: 트랙 관리 (MIDI Key Commands)
**As a** 음악 프로듀서, **I want** "새 오디오 트랙 만들어줘", "트랙 3 뮤트해줘"가 작동하는 것, **so that** 트랙 관리를 대화로 처리할 수 있다.

**Acceptance Criteria:**
- [ ] AC-4.1: Given MIDI Key Commands 프리셋 설치됨, when `logic_tracks("create_audio")` 호출, then MIDI CC로 ⌘⌥A 키커맨드 트리거 → 새 오디오 트랙 생성
- [ ] AC-4.2: Given MCU 연결, when `logic_tracks("mute", {index: 3, enabled: true})` 호출, then 트랙 3 뮤트
- [ ] AC-4.3: Given MCU 연결, when `logic_tracks("solo", {index: 3, enabled: true})` 호출, then 트랙 3 솔로
- [ ] AC-4.4: Given MCU 피드백, when 트랙 상태 변경, then `logic://tracks` 리소스에 반영

### US-5: MIDI 입력 + 피아노롤 편집
**As a** 음악 프로듀서, **I want** "C 메이저 코드를 4비트 길이로 삽입해줘"가 작동하는 것, **so that** 피아노롤 편집을 대화로 할 수 있다.

**Acceptance Criteria:**
- [ ] AC-5.1: Given CoreMIDI 연결, when `logic_midi("send_chord", {notes: [60,64,67], velocity: 100, duration_ms: 1000})` 호출, then MIDI 코드 전송
- [ ] AC-5.2: Given Step Input 모드 활성, when `logic_midi("step_input", {note: 60, duration: "1/4"})` 호출, then 피아노롤에 C4 쿼터노트 삽입
- [ ] AC-5.3: Given MIDI Key Commands, when `logic_edit("quantize", {value: "1/16"})` 호출, then 선택된 노트 1/16 퀀타이즈
- [ ] AC-5.4: Given Logic Pro 실행 중, when `logic_edit("toggle_step_input")` 호출, then Step Input Keyboard 토글 (MIDI Key Command: ⌥⌘K)

### US-6: 프로젝트 관리 (AppleScript)
**As a** 음악 프로듀서, **I want** "프로젝트 저장해줘", "WAV로 바운스해줘"가 작동하는 것, **so that** 프로젝트 관리를 대화로 처리할 수 있다.

**Acceptance Criteria:**
- [ ] AC-6.1: Given Logic Pro 실행 중, when `logic_project("save")` 호출, then 현재 프로젝트 저장 (⌘S)
- [ ] AC-6.2: Given Logic Pro 실행 중, when `logic_project("bounce", {format: "wav"})` 호출, then 바운스 다이얼로그 트리거. 즉시 성공 반환 (바운스 완료는 비동기)
- [ ] AC-6.3: Given 경로 파라미터에 특수문자 포함, when `logic_project("open", {path: "..."})` 호출, then `NSWorkspace.shared.open(URL(fileURLWithPath:))` 사용으로 injection 원천 차단

### US-7: 상태 읽기 (MCU 피드백)
**As a** 음악 프로듀서, **I want** "지금 트랙 목록 보여줘", "마스터 볼륨이 얼마야?"에 정확한 답을 받는 것, **so that** DAW 상태를 파악하고 지시할 수 있다.

**Acceptance Criteria:**
- [ ] AC-7.1: Given MCU 연결, when `logic://tracks` 리소스 읽기, then 모든 트랙의 이름/뮤트/솔로/Arm/오토메이션 모드 반환
- [ ] AC-7.2: Given MCU 연결, when `logic://mixer` 리소스 읽기, then 모든 채널의 볼륨/팬/인서트 정보 + MCU 연결 상태(`isConnected`, `registeredAsDevice`) 반환
- [ ] AC-7.3: Given MCU 연결, when `logic://transport/state` 리소스 읽기, then 재생/녹음/템포/위치/사이클 정보 반환
- [ ] AC-7.4: Given MCU 연결 상태, when Logic Pro에서 페이더 수동 이동, then `logic://mixer` 리소스 조회 시 변경값 반영까지 < 500ms (MCU feedback 수신 → StateCache 갱신 → 다음 리소스 응답 기준)

### US-8: 네비게이션 + 편집 (MIDI Key Commands + MCU)
**As a** 음악 프로듀서, **I want** "30번 마디로 이동", "undo", "선택 영역 복사"가 작동하는 것, **so that** 편집 작업을 대화로 할 수 있다.

**Acceptance Criteria:**
- [ ] AC-8.1: Given MCU 연결, when `logic_navigate("goto_bar", {bar: 30})` 호출, then 플레이헤드가 30번 마디로 이동
- [ ] AC-8.2: Given MIDI Key Commands, when `logic_edit("undo")` 호출, then ⌘Z 트리거
- [ ] AC-8.3: Given MIDI Key Commands, when `logic_navigate("toggle_view", {view: "mixer"})` 호출, then X 키 트리거 → 믹서 뷰 토글

### US-9: 오토메이션 (MCU)
**As a** 음악 프로듀서, **I want** "트랙 1 오토메이션 Touch 모드로 변경"이 작동하는 것, **so that** 오토메이션 워크플로우를 제어할 수 있다.

**Acceptance Criteria:**
- [ ] AC-9.1: Given MCU 연결, when `logic_tracks("set_automation", {index: 1, mode: "touch"})` 호출, then 트랙 1 오토메이션 모드 Touch로 변경
- [ ] AC-9.2: Given MCU 연결, when `logic://tracks` 리소스 읽기, then 각 트랙의 현재 오토메이션 모드(off/read/touch/latch/write) 반환

## 4. Technical Design

### 4.1 Architecture Overview

**7채널**: MCU, MIDIKeyCommands, CoreMIDI, Scripter, AppleScript, CGEvent, Accessibility(보조)

```
Claude/AI ──── 8 MCP Dispatcher Tools ──── logic_transport()
           │   7 MCP Resources              logic_tracks()
           │   (zero tool cost)             logic_mixer()
           ▼                                logic_midi()
                                            logic_edit()
                                            logic_navigate()
                                            logic_project()
                                            logic_system()
     ┌─── LogicProMCP Server ──────────────────────────────────────────┐
     │  Command Dispatcher → Channel Router (priority + fallback)       │
     │     │        │        │        │        │       │       │        │
     │   MCU    MIDIKeyCmds CoreMIDI Scripter  AS    CGEvent   AX      │
     │  <2ms     <2ms       <1ms     <5ms    ~200ms   <2ms   ~15ms     │
     │   ↕        ↓          ↕        ↓        ↓       ↓      ↓       │
     │  Logic   Logic      Logic   Logic    Logic   Logic   Logic      │
     │  (CS)   (KeyCmd)   (MIDI)  (MIDIFX) (AS)   (KB)    (AX)       │
     └──────────────────────────────────────────────────────────────────┘
         ↕ = 양방향    ↓ = 단방향

     State Layer (event-driven + supplementary polling):
     ┌─── MCU Feedback Parser (primary, event-driven) ─────────────────┐
     │  LCD SysEx → Channel Names, Parameter Values                     │
     │  Note On/Off → Mute/Solo/Arm/Select LED states                   │
     │  Pitch Bend → Fader positions (volume per channel)                │
     │  → StateCache (actor)                                             │
     ├─── AX Poller (supplementary, 5s interval) ──────────────────────┤
     │  Regions, Markers, ProjectInfo (MCU가 커버하지 않는 데이터)        │
     │  → StateCache (actor) → MCP Resources (7 URIs)                   │
     └──────────────────────────────────────────────────────────────────┘
```

### 4.2 Data Model Changes

기존 `StateModels.swift` 확장:

```
TransportState     (기존 유지 + MCU 피드백 소스 변경)
TrackState         (기존 확장: automationMode 추가)
ChannelStripState  (신규: volume, pan, inserts[], sends[])
PluginState        (신규: name, params[])
MCUDisplayState    (신규: LCD text per channel, mode indicator)
MCUConnectionState (신규: isConnected, registeredAsDevice, lastFeedbackAt)
```

### 4.3 API Design (MCP Tools — 기존 8개 유지)

| Tool | Primary Channel | Fallback Chain | 변경사항 |
|------|----------------|----------------|---------|
| `logic_transport` | MCU | CoreMIDI → CGEvent | 기존 유지 + MCU primary. **set_tempo는 MIDIKeyCmds primary** |
| `logic_tracks` | MCU | MIDIKeyCmds → CGEvent | MCU 뮤트/솔로/Arm + KeyCmd 생성/삭제 |
| `logic_mixer` | MCU | (없음 — MCU 전용) | **전면 재작성**: MCU 기반. MCU 미연결 시 에러 반환 |
| `logic_midi` | CoreMIDI | (없음) | Step Input 모드 추가 |
| `logic_edit` | MIDIKeyCmds | CGEvent | **primary 변경**: KeyCmd 우선 |
| `logic_navigate` | MCU + MIDIKeyCmds | CGEvent | MCU Jog + KeyCmd 뷰 전환 |
| `logic_project` | AppleScript | MIDIKeyCmds | injection 수정 (NSWorkspace.open) |
| `logic_system` | Internal | (없음) | MCU health + 채널 상태 + 메모리/CPU 추가 |

### 4.3.1 MCP Tool Contract Changes (기존 코드 대비 Delta)

**신규 Commands (기존 Dispatcher에 없음):**

| Tool | Command | Params | Notes |
|------|---------|--------|-------|
| `logic_mixer` | `set_plugin_param` | `{track: Int, insert: Int, param: Int, value: Float}` | MCU Plugin 모드. 기존 `insert_plugin`/`bypass_plugin`과 별개 |
| `logic_midi` | `step_input` | `{note: Int, duration: String}` | Step Input 모드 활성 전제 |
| `logic_edit` | `toggle_step_input` | `{}` | MIDIKeyCmd ⌥⌘K |
| `logic_tracks` | `set_automation` | `{index: Int, mode: String}` | MCU Automation 버튼 |

**변경 Commands (파라미터/동작 변경):**

| Tool | Command | Before | After | Notes |
|------|---------|--------|-------|-------|
| `logic_mixer` | `set_pan` | value: -1.0~+1.0 | value: -1.0~+1.0 **(유지)** | PRD AC에서 -30 → -0.3 으로 수정 |
| `logic_mixer` | `set_send` | bus: Int | bus: Int **(유지)** | PRD AC에서 send → bus로 수정 |
| `logic_transport` | `set_tempo` | 채널: AppleScript/CGEvent | 채널: **MIDIKeyCmd (primary)** | MCU에 네이티브 tempo set 없음 |

**Deprecated (제거 예정 없음, 기존 계약 유지):**
- 기존 MixerDispatcher의 `set_volume`, `set_pan`, `set_send`, `set_output`, `set_input`, `set_master_volume`, `toggle_eq`, `reset_strip`, `insert_plugin`, `bypass_plugin` — 모두 유지. 채널만 MCU로 변경.

### 4.3.2 `logic_system("health")` JSON Response Schema

```json
{
  "logic_pro_running": true,
  "logic_pro_version": "12.0.1",
  "mcu": {
    "connected": true,
    "registered_as_device": true,
    "last_feedback_at": "2026-04-04T22:45:00Z",
    "feedback_stale": false,
    "port_name": "LogicProMCP-MCU-Internal"
  },
  "channels": [
    {
      "channel": "mcu",
      "available": true,
      "latency_ms": 1.2,
      "detail": "MCU connected, feedback active"
    },
    {
      "channel": "midi_key_commands",
      "available": true,
      "latency_ms": 0.8,
      "detail": "Preset installed, 80 commands mapped"
    }
  ],
  "cache": {
    "poll_mode": "active",
    "transport_age_sec": 0.3,
    "track_count": 24,
    "project": "My Song.logicx"
  },
  "permissions": {
    "accessibility": true,
    "automation": true
  },
  "process": {
    "memory_mb": 32.4,
    "cpu_percent": 0.2,
    "uptime_sec": 86400
  }
}
```

### 4.3.3 Resource Response Schemas (Skeleton)

**`logic://tracks` 응답** (현재 `TrackState` + `automationMode` 추가):

```json
[
  {
    "id": 0,
    "name": "Vocals",
    "type": "audio",
    "isMuted": false,
    "isSoloed": false,
    "isArmed": true,
    "isSelected": true,
    "volume": 0.0,
    "pan": 0.0,
    "automationMode": "read"
  }
]
```

> Delta: 현재 `StateModels.swift:30` `TrackState`에 `automationMode` 필드 없음 → Phase 2에서 추가.

**`logic://mixer` 응답** (현재 `ChannelStripState` + MCU 연결 메타 추가):

```json
{
  "mcu_connected": true,
  "strips": [
    {
      "trackIndex": 0,
      "volume": 0.75,
      "pan": -0.3,
      "sends": [{"index": 0, "destination": "Bus 1", "level": 0.5, "isPreFader": false}],
      "eqEnabled": true,
      "plugins": [{"index": 0, "name": "Channel EQ", "isBypassed": false}]
    }
  ]
}
```

> Delta: 현재 `ResourceHandlers.swift:75` `readMixer()`는 `ChannelStripState` 배열만 반환 → Phase 5에서 wrapper 객체로 변경.

### 4.3.4 Destructive Operation Wire Format

L3 명령(`quit`, `close`) 호출 시 응답:

```json
{
  "status": "confirmation_required",
  "command": "quit",
  "level": "L3",
  "message": "Logic Pro를 종료합니다. 미저장 변경사항이 있을 수 있습니다.",
  "confirm_command": "logic_project(\"quit\", {confirmed: true})"
}
```

`confirmed: true` 파라미터 포함 재호출 시 실제 실행. 미포함 시 위 응답만 반환.

> Delta: 현재 `ProjectDispatcher.swift:94` `quit`은 즉시 실행 + plain text 반환 → Phase 5에서 확인 플로우 추가.

### 4.4 Key Technical Decisions

| Decision | Options Considered | Chosen | Rationale |
|----------|-------------------|--------|-----------|
| 믹서 제어 프로토콜 | OSC / AX / MCU | **MCU** | Logic Pro 네이티브 지원, 양방향, 14-bit 해상도 |
| 키보드 단축키 방식 | CGEvent / MIDI Key Commands | **MIDI Key Commands (primary)** | 로케일 무관, 포커스 불필요, 안정적 |
| 플러그인 파라미터 | MCU만 / Scripter만 / MCU+Scripter | **MCU + Scripter** | MCU로 범용 제어, Scripter로 딥 제어 |
| 상태 읽기 방식 | AX polling only / MCU feedback only / Hybrid | **Hybrid** (MCU primary + AX supplementary) | MCU는 event-driven(믹서/트랙), AX는 보충(Region/Marker/ProjectInfo) |
| OSC 채널 | 유지 / 제거 | **제거** | Logic Pro 네이티브 OSC 미지원 |
| CGEvent 채널 | 유지 / 제거 | **축소 유지 (fallback)** | MIDI Key Cmds 불가능한 극소수 동작용 |
| AX 채널 | 유지 / 제거 | **보조 유지** | MCU 미커버 데이터(Region/Marker/ProjectInfo) 보충 |
| 가상 MIDI 포트 | CoreMIDI API / IAC Driver | **CoreMIDI API** | 프로그래밍 제어, IAC 수동 설정 불필요 |
| AppleScript open 방식 | 문자열 보간 / NSWorkspace.open | **NSWorkspace.shared.open(URL(fileURLWithPath:))** | injection 원천 차단, AppleScript 파서 우회 |

### 4.5 MCU Protocol Specification

Logic Pro의 Mackie Control Universal 프로토콜 바이트 레벨 스펙.

**Faders (Controller → Logic):**

| Channel Strip | MIDI Message | Range | Notes |
|--------------|-------------|-------|-------|
| Strip 1-8 | Pitch Bend ch 0-7 | 0x0000-0x3FFF (14-bit) | MSB=value>>7, LSB=value&0x7F |
| Master | Pitch Bend ch 8 | 0x0000-0x3FFF | |

**Faders (Logic → Controller, feedback):**

| 동일 포맷 | Pitch Bend ch 0-8 | Logic이 현재 페이더 위치를 MCU로 전송 |

**Channel Strip Buttons (Note On/Off):**

| Function | Note Numbers (strip 1-8) | Velocity | Notes |
|----------|-------------------------|----------|-------|
| Rec/Arm | 0x00-0x07 | 0x7F=on, 0x00=off | |
| Solo | 0x08-0x0F | 0x7F=on, 0x00=off | |
| Mute | 0x10-0x17 | 0x7F=on, 0x00=off | |
| Select | 0x18-0x1F | 0x7F=on, 0x00=off | |

**V-Pot (Rotary Encoders):**

| Direction | MIDI Message | Value | Notes |
|-----------|-------------|-------|-------|
| CW (clockwise) | CC 0x10-0x17 | 0x01-0x0F (speed) | Relative encoding |
| CCW | CC 0x10-0x17 | 0x41-0x4F (speed) | Bit 6 = direction |

**Transport Buttons (Note On, velocity 0x7F):**

| Function | Note Number |
|----------|------------|
| Rewind | 0x5B |
| Fast Forward | 0x5C |
| Stop | 0x5D |
| Play | 0x5E |
| Record | 0x5F |
| Cycle | 0x56 |
| Drop (punch in) | 0x57 |
| Replace | 0x58 |
| Click | 0x59 |
| Solo (global) | 0x5A |

**Banking:**

| Function | Note Number |
|----------|------------|
| Bank Left | 0x2E |
| Bank Right | 0x2F |
| Channel Left | 0x30 |
| Channel Right | 0x31 |

**Assignment Modes:**

| Mode | Note Number | Description |
|------|------------|-------------|
| Track | 0x28 | Track parameters |
| Send | 0x29 | Send levels |
| Pan/Surround | 0x2A | Pan control |
| Plug-in | 0x2B | Plugin parameters |
| EQ | 0x2C | EQ control |
| Instrument | 0x2D | Instrument parameters |

**Automation:**

| Mode | Note Number |
|------|------------|
| Read/Off | 0x4A |
| Write | 0x4B |
| Trim | 0x4C |
| Touch | 0x4D |
| Latch | 0x4E |

**Jog Wheel:**

| Direction | MIDI Message | Value |
|-----------|-------------|-------|
| CW | CC 0x3C | 0x01 |
| CCW | CC 0x3C | 0x41 |

**LCD Display (Logic → Controller):**

```
SysEx: F0 00 00 66 14 12 [offset] [char1] [char2] ... F7
  - offset: 0x00-0x6F (0-111, 2 rows × 56 chars)
  - Row 1 (upper): offset 0x00-0x37 (channel names)
  - Row 2 (lower): offset 0x38-0x6F (parameter values)
  - chars: ASCII 7-bit
```

**Connection Handshake:**

MCU 컨트롤러 ↔ Logic Pro 연결 확립 절차. Phase 0 스파이크에서 실측 후 확정.

| Scenario | Procedure |
|----------|-----------|
| **A: 수동 등록** (Logic Pro Control Surfaces > Setup에서 Mackie Control 추가) | MCUChannel.start()에서 포트 생성 후 Device Query SysEx 전송 → 응답 대기(2초). 응답 없으면 `MCUConnectionState.registeredAsDevice = false` 설정 + 사용자에게 등록 가이드 제공. 포트 이름: `LogicProMCP-MCU-Internal` (Logic Pro Setup에서 이 이름으로 MIDI In/Out 할당) |
| **B: 자동 핸드셰이크** (Logic Pro가 가상 포트를 자동 감지) | MCUChannel.start()에서 포트 생성 → Device Query SysEx `F0 00 00 66 14 00 F7` 전송 → Logic Pro 응답 `F0 00 00 66 14 01 ... F7` 수신 → `registeredAsDevice = true`. 응답 없으면 Scenario A로 fallback |

MCUChannel.start() 구현 계약:
1. 가상 MIDI 포트 생성 (`LogicProMCP-MCU-Internal`)
2. Device Query SysEx 전송: `F0 00 00 66 14 00 F7`
3. 2초 대기 → 응답 수신 시 `registeredAsDevice = true`
4. 미응답 시 `registeredAsDevice = false` + 로그 경고 + health에 미등록 표시
5. 이후 명령 실행 시 `registeredAsDevice == false`이면 E3 동작 (에러 + 가이드)

**Time Code Display (Logic → Controller):**

```
CC 0x40-0x49: digits 0-9 of timecode display (right to left)
  - Value: ASCII character code (0x30-0x39 for '0'-'9', 0x20 for space)
  - Bit 6 (0x40): decimal point indicator
```

### 4.6 MIDI Port Architecture

기존 `MIDIEngine`(싱글 클라이언트/소스/대상)을 멀티포트로 확장.

| Port Name | Type | Purpose | Channel |
|-----------|------|---------|---------|
| `LogicProMCP-MCU` | Source + Destination (bidirectional) | MCU 프로토콜 송수신 | MCUChannel |
| `LogicProMCP-MIDI` | Source + Destination (bidirectional) | MIDI 노트/CC + Step Input | CoreMIDIChannel |
| `LogicProMCP-KeyCmd` | Source only (send) | MIDI Key Commands 전송 | MIDIKeyCommandsChannel |
| `LogicProMCP-Scripter` | Source only (send) | Scripter MIDI FX CC 전송 | ScripterChannel |

**구현 방식**: `MIDIPortManager` actor 신규 생성. 포트 이름별 `MIDIPort` 인스턴스 관리. 기존 `MIDIEngine`은 `MIDIPortManager`를 통해 포트 접근.

**포트 이름 충돌 방지**: 시작 시 `MIDIGetNumberOfSources/Destinations` 순회하여 동일 이름 존재 확인. 존재하면 기존 포트 endpoint 재사용. 재사용 불가 시 suffix 추가 (`LogicProMCP-MCU-2`).

**포트 생명주기**: 서버 start()에서 생성, stop()에서 `MIDIEndpointDispose`로 즉시 해제. 다른 MIDI 앱(GarageBand 등)이 자동 연결하는 것을 방지하기 위해 포트 이름에 `Internal` 접미어 고려 (예: `LogicProMCP-MCU-Internal`).

### 4.7 Scripter Bridge Protocol

Scripter는 Logic Pro 내장 JavaScript MIDI FX 플러그인. 채널 스트립에 삽입하면 MIDI 입력을 받아 플러그인 파라미터를 제어 가능.

**CC 매핑 규칙:**

| MIDI CC | Target | Notes |
|---------|--------|-------|
| CC 102 | Plugin Parameter 1 | TargetEvent index 0 |
| CC 103 | Plugin Parameter 2 | TargetEvent index 1 |
| ... | ... | ... |
| CC 119 | Plugin Parameter 18 | TargetEvent index 17 |
| MIDI Channel | 16 (관례적 미사용) | 일반 악기 연주와 충돌 방지 |

**Scripter JS 템플릿:**

```javascript
var PluginParameters = [];
for (var i = 0; i < 18; i++) {
    PluginParameters.push({name: "Param " + (i+1), type: "target"});
}

function HandleMIDI(event) {
    if (event instanceof ControlChange && event.channel == 16) {
        var paramIndex = event.number - 102;
        if (paramIndex >= 0 && paramIndex < 18) {
            var target = new TargetEvent();
            target.target = PluginParameters[paramIndex].name;
            target.value = event.value / 127.0;
            target.send();
        }
    } else {
        event.send(); // pass through
    }
}
```

**설치**: Scripter 채널은 optional. OQ-4 실측 결과에 따라 수동 설치 가이드 또는 자동화. Scripter 미설치 시 MCU 플러그인 모드로 fallback.

### 4.8 State Feedback Architecture

기존 StatePoller(AX pull 방식) → **Hybrid** (MCU push + AX supplementary pull)로 전환.

**MCU Feedback (primary, event-driven):**

```
MCUChannel.start() 내부에서 MIDI Input callback 등록
  → MIDIReadProc로 수신된 MIDI 바이트 파싱
  → MCUFeedbackParser.parse(bytes:) 호출
  → StateCache actor에 직접 업데이트:
      Pitch Bend → channelStrips[ch].volume
      Note On/Off 0x10-0x17 → channelStrips[ch].mute
      Note On/Off 0x08-0x0F → channelStrips[ch].solo
      Note On/Off 0x00-0x07 → channelStrips[ch].arm
      SysEx LCD → channelStrips[ch].name, parameterValues
      Transport buttons → transportState
```

**AX Supplementary Poller (5초 간격):**

MCU가 커버하지 않는 데이터만:
- ProjectInfo (프로젝트 이름, 샘플 레이트, 타임 시그니처)
- Regions (리전 목록 — AX 실측 결과에 따라 scope 결정)
- Markers (마커 목록 — AX 실측 결과에 따라 scope 결정)

**StatePoller 변경:**
- 기존 transport/tracks polling → **제거** (MCU feedback 대체)
- AX supplementary polling만 잔류 (5초 간격)
- `StatePoller.pollLoop()` → `AXSupplementaryPoller.pollLoop()`로 rename

**Verify-After-Write:**
MCU 명령 전송 후 MCU 피드백으로 실제 반영 확인. `MCUChannel.executeAndVerify()`:
1. 명령 MIDI 전송
2. 150ms 내 대응 피드백 대기 (예: set_volume → Pitch Bend 피드백)
3. 피드백 수신 → success + 실제 값 반환
4. 타임아웃 → warning 로그 + 명령은 success로 반환 (Logic Pro가 항상 피드백을 보장하지 않을 수 있음)

### 4.9 MCU Banking Transaction

8채널 초과 트랙 제어 시 뱅킹이 필요. **뱅킹은 MCU 상태를 변경하는 side effect**가 있으므로 atomic transaction으로 보호.

```
MCUChannel actor 내부:
  private var currentBank: Int = 0
  private var isBanking: Bool = false
  private var bankingQueue: [(operation, continuation)] = []

  func executeWithBanking(targetTrack: Int, operation: ...) async -> ChannelResult {
      let targetBank = targetTrack / 8
      if targetBank == currentBank {
          return await executeOnCurrentBank(operation)
      }

      // Atomic banking transaction
      isBanking = true
      defer { isBanking = false; drainBankingQueue() }

      // 1. Bank to target
      await sendBankChange(to: targetBank)
      await waitForBankFeedback(targetBank, timeout: 100ms)

      // 2. Execute command
      let result = await executeOnCurrentBank(operation)

      // 3. Restore original bank
      await sendBankChange(to: originalBank)
      await waitForBankFeedback(originalBank, timeout: 100ms)

      return result
  }
```

뱅킹 중 다른 명령 유입 시: `bankingQueue`에 대기. 현재 뱅킹 트랜잭션 완료 후 순차 처리. MCU 명령 간 최소 1ms 간격 보장 (CoreMIDI timestamp 활용).

### 4.10 Implementation Roadmap

**Phase 0 (Spike, 2일): 전제 검증**
- OQ-1 해소: 가상 MIDI 포트 생성 → Logic Pro 12.0.1에서 MCU로 인식되는지 실측
- OQ-2 해소: Key Commands .plist 직접 설치 가능 여부 실측
- OQ-3: AX 트리 스캔 (보조 채널 scope 결정)
- **테스트 환경 검증**: `swift test` 실행 가능 여부 확인. XCTest 경로 이슈 해소 방법 결정 (xcodebuild / Swift Testing / Xcode toolchain 전환)
- 결과에 따라 설치 스크립트 설계 확정 + Appendix A 커버리지 재산정

**Phase 1 (M): 기반 정리**
- **테스트 하네스 정비** (GATE): `swift test` 실행 가능 상태 확보. 현재 `no such module 'XCTest'` 에러 → Package.swift testTarget 수정 또는 Swift Testing framework 전환. **Phase 2 진입 전 `swift test` PASS 필수.**
- OSC 채널 제거 (OSCChannel, OSCClient, OSCServer, OSCMessageBuilder)
- ServerConfig에서 OSC 관련 상수 제거
- MIDIPortManager actor 신규 생성 (멀티포트)
- MIDIFeedback.parseBytes running status 처리 추가
- MIDIEngine.sendRawBytes MIDIPacketListAdd 반환값 검증 추가
- Channel 프로토콜에 ChannelID enum 업데이트 (.mcu, .midiKeyCommands, .scripter 추가)

**Phase 2 (L): MCU 채널**
- MCUProtocol.swift: 인코더/디코더 (§4.5 스펙 기반)
- MCUFeedbackParser.swift: MIDI 피드백 → StateCache 갱신
- MCUChannel.swift: Channel 프로토콜 구현 + executeAndVerify + 뱅킹 트랜잭션
- StateCache: MCU feedback event-driven 갱신 경로 추가
- MCUConnectionState 모델 추가

**Phase 3 (M): MIDI Key Commands 채널**
- MIDIKeyCommandsChannel.swift: Channel 프로토콜 구현
- Key Commands 매핑 테이블 (Appendix B)
- Logic Pro Key Commands 프리셋 .plist 생성기
- 프리셋 설치/백업/복구 스크립트 → `Scripts/install-keycmds.sh` (Phase 3에서 생성)

**Phase 4 (S): Scripter 채널**
- ScripterChannel.swift: Channel 프로토콜 구현
- Scripter JS 템플릿 파일 → `Scripts/LogicProMCP-Scripter.js` (Phase 4에서 생성)
- 설치 가이드

**Phase 5 (L): 라우팅 + Dispatcher + 상태**
- ChannelRouter: 라우팅 테이블 전면 교체 (7채널 + §4.3 매핑)
- 8 Dispatchers: operation key 정합성 전수 수정
- AXSupplementaryPoller: StatePoller 축소 → AX 보충 전용
- AppleScript injection 수정 (NSWorkspace.open + action whitelist)

**Phase 6 (M): 테스트 + 빌드**
- Unit: MCU encode/decode, ChannelRouter, StateCache, MIDIFeedback (running status)
- Integration: MCU loopback, CoreMIDI send/receive
- Edge case: E1-E15 전체
- 빌드 검증: swift build -c release

### 4.11 MIDI Key Commands Mapping Table (Appendix B 요약)

MIDI Channel 16, CC 범위 20-99 사용 (CC 0-19는 MSB/LSB 예약, CC 102-119는 Scripter 전용).

| CC# | Logic Pro Key Command | Shortcut |
|-----|----------------------|----------|
| 20 | New Audio Track | ⌘⌥A |
| 21 | New Software Instrument Track | ⌘⌥S |
| 22 | New External MIDI Track | ⌘⌥X |
| 23 | Duplicate Track | ⌘D |
| 24 | Delete Track | ⌘⌫ |
| 25 | Create Track Stack | ⌘⇧D |
| 30 | Undo | ⌘Z |
| 31 | Redo | ⌘⇧Z |
| 32 | Cut | ⌘X |
| 33 | Copy | ⌘C |
| 34 | Paste | ⌘V |
| 35 | Select All | ⌘A |
| 36 | Trim at Playhead | ⌘T |
| 37 | Bounce In Place | ⌃B |
| 40 | Quantize | Q |
| 41 | Force Legato | F2 |
| 42 | Remove Overlaps | F1 |
| 43 | Join Notes | ⌘J |
| 44 | Toggle Step Input Keyboard | ⌥⌘K |
| 50 | Toggle Mixer | X |
| 51 | Toggle Piano Roll | P |
| 52 | Toggle Score Editor | N |
| 53 | Toggle List Editors | D |
| 54 | Toggle Smart Controls | B |
| 55 | Toggle Library | Y |
| 56 | Toggle Inspector | I |
| 57 | Toggle Automation | A |
| 58 | Show/Hide All Plugin Windows | V |
| 60 | Save | ⌘S |
| 61 | Save As | ⌘⇧S |
| 62 | Bounce | ⌘B |
| 63 | Export Selection as MIDI | ⌥⌘E |
| 70 | Set Tempo (opens tempo field) | Custom |
| 71 | Toggle Click | K |
| 72 | Toggle Cycle | C |
| 73 | Capture Recording | ⇧R |
| 80 | Automation Off | ⌃⌘O |
| 81 | Automation Read | ⌃⇧⌘R |
| 82 | Automation Touch | ⌃⇧⌘T |
| 83 | Automation Latch | ⌃⇧⌘L |
| 90 | Note Up Semitone | ⌥↑ |
| 91 | Note Down Semitone | ⌥↓ |
| 92 | Note Up Octave | ⇧⌥↑ |
| 93 | Note Down Octave | ⇧⌥↓ |

전체 매핑은 `Scripts/keycmd-preset.plist`에 생성.

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | Logic Pro 미실행 상태에서 MCP 서버 시작 | 서버 시작 성공, 채널 unavailable 상태. Logic Pro 시작 시 자동 연결 | Medium |
| E2 | MCU 가상 MIDI 포트 생성 실패 | 에러 로그 + fallback 채널(CoreMIDI, CGEvent)으로 degraded 모드 | High |
| E3 | Logic Pro에서 MCU(Mackie Control) 등록 안 됨 | MCU 명령 전송 시 150ms 이내 피드백 미수신 → 자동 감지 → `logic_system("health")`에서 MCU 미등록 경고 + 등록 가이드 | High |
| E4 | 8채널 초과 트랙에서 뱅킹 필요 | §4.9 Banking Transaction: bank→execute→restore atomic. 뱅킹 중 다른 명령은 큐 대기 | Medium |
| E5 | Scripter 스크립트가 채널에 미설치 | Scripter 필요 명령 시 MCU 플러그인 모드 fallback 또는 에러 + 설치 가이드 | Low |
| E6 | MIDI Key Commands 프리셋 미설치 | CGEvent fallback + 프리셋 설치 가이드 | Medium |
| E7 | AppleScript 경로에 특수문자 | NSWorkspace.shared.open(URL(fileURLWithPath:))로 injection 원천 차단 | High |
| E8 | MCU LCD SysEx 파싱 오류 | 파싱 실패 시 해당 필드만 "unknown" + 에러 로그, 다른 피드백은 정상 처리 | Low |
| E9 | 동시 다발적 명령 (빠른 연속 호출) | MCU: actor 격리 + 뱅킹 lock + 명령 간 최소 1ms 간격 (CoreMIDI timestamp). 채널별 독립 실행 | Medium |
| E10 | Logic Pro 크래시/강제종료 중 | ProcessUtils.isLogicProRunning 감지 → 모든 채널 unavailable → 재시작 시 자동 복구 | High |
| E11 | Accessibility 권한 미부여 | CGEvent/AX 채널 unavailable. MCU + MIDIKeyCmds + CoreMIDI + AppleScript만 가용. 권한 요청 가이드 | Medium |
| E12 | Automation 권한 미부여 | AppleScript 채널 unavailable. MIDIKeyCmds fallback(⌘S 등) | Medium |
| E13 | 기존 하드웨어 MCU 컨트롤러 공존 | Logic Pro Control Surface에 별도 유닛(Unit 2+)으로 등록. 충돌 감지 시 에러 + 가이드 | Medium |
| E14 | 동일 이름 가상 MIDI 포트 존재 | 기존 포트 endpoint 재사용. 불가 시 suffix 추가 | Low |
| E15 | 뱅킹 중 Logic Pro에서 트랙 추가/삭제 | 뱅킹 전후 트랙 수 확인 + 명령 후 대상 트랙 이름 검증. 불일치 시 재뱅킹 + 재시도 (최대 2회) | Medium |

## 6. Security & Permissions

### 6.1 Authentication
로컬 전용 MCP 서버. 네트워크 노출 없음. stdio transport.
Trust boundary: MCP 호스트 프로세스(Claude Desktop/Code 등)를 신뢰한다. 호스트 프로세스 자체의 보안은 이 서버의 범위 밖이다.

### 6.2 Authorization
macOS 권한 2개 필요:
- **Accessibility** (Privacy & Security > Accessibility) — CGEvent, AX 채널용
- **Automation** (Privacy & Security > Automation > Logic Pro) — AppleScript 채널용

권한 미부여 시: 해당 채널만 unavailable, 나머지 정상 동작 (E11, E12 참조).

### 6.3 Data Protection

**AppleScript injection 수정 (구체 패턴):**
- `project.open` → `NSWorkspace.shared.open(URL(fileURLWithPath: path))` 사용. AppleScript 파서를 완전 우회.
- `project.new/close/save` → 화이트리스트된 AppleScript 템플릿 (파라미터 보간 없음)
- `transport` action → switch 분기 + 화이트리스트: `["play","stop","record","pause"]`. 그 외 → 에러 반환.

**MIDI Key Commands 프리셋 보호:**
- 백업 위치: `~/Library/Application Support/Logic/Key Commands/UserBackup_YYYYMMDD_HHMMSS.plist`
- 사용 CC 범위: CC 20-99 + MIDI Channel 16 (관례적 미사용, GM spec undefined)
- 설치 전 기존 .plist 스캔 → 사용 중인 CC 충돌 감지 → 충돌 시 경고 + 대체 CC 제안
- `Scripts/uninstall-keycmds.sh` (Phase 3에서 생성): 백업에서 원래 매핑 복원

**MIDI SysEx 입력 검증:**
- `sendSysEx`: F0/F7 체크 + 중간 바이트 7-bit 범위(< 0x80) 검증

### 6.4 Destructive Operation Safety Policy

상태를 변경하거나 데이터 손실을 유발할 수 있는 MCP tool 명령에 대한 안전 정책.

**위험 등급:**

| Level | Commands | Policy |
|-------|----------|--------|
| **L3 (Critical)** | `quit`, `close` | 응답에 `requiresConfirmation: true` 포함. AI 호스트가 사용자 확인 후 재호출. 미저장 변경 있을 시 경고 메시지 포함 |
| **L2 (High)** | `save_as`, `bounce`, `open` (현재 프로젝트 닫힘) | 응답에 `warning` 필드로 부작용 고지. 즉시 실행하되 로그 기록 |
| **L1 (Normal)** | `save`, `new`, `launch` | 즉시 실행. 로그 기록 |
| **L0 (Safe)** | 나머지 (play, stop, set_volume 등) | 즉시 실행. 로그 없음 |

**감사 로그:**
L1 이상 명령 실행 시 `Log.info("[AUDIT] {command} executed at {timestamp}")` 기록. 로그 레벨 Info.

**실패 시 복구:**
- `save` 실패: 에러 반환 + "수동 저장 권장" 메시지
- `quit` 실패: Logic Pro 프로세스 상태 확인 + 재시도 안내
- `bounce` 실패: 에러 반환 (바운스는 비동기이므로 시작 실패만 감지 가능)

**구현**: `ProjectDispatcher.handle()` 상단에 `destructiveLevel(for: command)` 체크 → L3이면 `requiresConfirmation` 응답 패턴 적용.

## 7. Performance & Monitoring

| Metric | Target | Measurement |
|--------|--------|-------------|
| MCU single message latency | < 5ms | CoreMIDI send timestamp (단일 MIDI 메시지 기준) |
| MCU banking round-trip | < 50ms | bank + execute + restore end-to-end |
| MIDI Key Command latency | < 5ms | CoreMIDI send timestamp |
| Transport response (play/stop) | < 50ms | Command send → MCU feedback received |
| State feedback update | < 500ms | MCU feedback 수신 → StateCache 갱신 → 다음 리소스 응답 기준 |
| Memory usage | < 50MB | `logic_system("health")`에서 `ProcessInfo.processInfo` 기반 자동 수집 |
| CPU idle | < 1% | `logic_system("health")`에서 `rusage` 기반 자동 수집 |

### 7.1 Monitoring & Alerting
- `logic_system("health")` 도구로 모든 채널 상태 + 레이턴시 + 메모리/CPU 실시간 조회
- 로그 레벨: Error, Warn, Info, Debug (런타임 변경 가능)
- MCU 연결 끊김 시 StateCache에 "stale" 플래그 + 재연결 시도

## 8. Testing Strategy

### 8.1 Unit Tests
- MCU 프로토콜 메시지 인코딩/디코딩 (§4.5 스펙 기반 — Pitch Bend, Note On/Off, SysEx LCD, V-Pot, Jog)
- MCU Banking Transaction (atomic, queue, 재뱅킹)
- MCUFeedbackParser (LCD SysEx, fader positions, button states)
- MIDIFeedback 파싱 (running status 포함)
- ChannelRouter 라우팅 + fallback 로직 (7채널)
- StateCache actor 동시성 안전
- MIDI Key Commands 매핑 테이블 정합성
- AppleScript injection 방지 (NSWorkspace.open, action whitelist)
- MMC 명령 SysEx 포맷
- MIDIEngine.sendRawBytes: MIDIPacketListAdd 반환값 검증, 대용량 SysEx 분할

### 8.2 Integration Tests
- MCU 가상 포트 생성 → loopback 메시지 송수신 (실제 Logic Pro 불필요)
- CoreMIDI 포트 생성 + Note/CC 전송
- ChannelRouter → 채널 execute → 결과 검증

**Mock 전략:** MCU 레이어를 protocol로 추상화. `MockMCUTransport`로 fixture 데이터(실제 Logic Pro 세션에서 캡처한 SysEx) 기반 테스트.

### 8.3 Edge Case Tests
- Section 5의 E1-E15 각각에 대한 테스트
- 특수문자 경로 AppleScript 안전성 (quotes, backslash, newline, $, backtick)
- 8채널 초과 뱅킹 시나리오 (뱅킹 중 다른 명령 유입)
- 동시 다발적 명령 큐잉

## 9. Rollout Plan

### 9.1 Migration Strategy
기존 v1 바이너리 사용자: 바이너리 교체 + Logic Pro MCU 등록 + Key Commands 프리셋 설치.
설치 스크립트(`Scripts/install.sh`) 업데이트로 자동화.

### 9.2 Feature Flag
N/A — 개인 사용, 점진적 릴리스 불필요.

### 9.3 Rollback Plan
코드: `git revert` 또는 `git checkout <tag> && swift build -c release`

Logic Pro 설정 복원:
1. Control Surfaces > Setup에서 MCU 가상 장치 제거
2. `Scripts/uninstall-keycmds.sh` (Phase 3에서 생성) 실행 → 백업에서 원래 Key Commands 복원
3. Scripter 스크립트: 해당 채널 스트립에서 수동 삭제

`Scripts/uninstall.sh` (Phase 5에서 생성)로 1-3 자동화.

**Planned Artifacts** (기존: `Scripts/install.sh`만 존재):

| Artifact | 생성 Phase | 용도 |
|----------|-----------|------|
| `Scripts/install-keycmds.sh` | Phase 3 | Key Commands 프리셋 설치 + 백업 |
| `Scripts/uninstall-keycmds.sh` | Phase 3 | Key Commands 원래 매핑 복원 |
| `Scripts/keycmd-preset.plist` | Phase 3 | MIDI CC → Key Command 매핑 데이터 |
| `Scripts/LogicProMCP-Scripter.js` | Phase 4 | Scripter MIDI FX JS 템플릿 |
| `Scripts/uninstall.sh` | Phase 5 | 전체 설정 롤백 자동화 |

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if Delayed |
|-----------|-------|--------|-----------------|
| MCP Swift SDK 0.10+ | modelcontextprotocol | Stable | Low — 이미 사용 중 |
| CoreMIDI framework | Apple | Stable | None |
| Logic Pro 12.0.1 (Build 6590) MCU support | Apple | Stable | None — 20년+ 지원 |
| Logic Pro Key Commands | Apple | Stable | Low — 매 버전 대부분 유지 |

### 10.2 Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Logic Pro 업데이트로 AX 트리 변경 | Medium | Low | AX는 보조 채널, MCU/KeyCmd 불영향 |
| MCU 프로토콜 세부 동작 미문서화 | Medium | Medium | Phase 0 스파이크에서 실측 + 기존 MCU 에뮬레이터 참조 |
| Logic Pro Key Commands CC 충돌 | Medium | Medium | CC 20-99 + CH 16 전용. 설치 전 충돌 감지 + 백업 |
| Scripter 스크립트 수동 설치 필요 (OQ-4) | High | Low | MCU fallback. 설치 가이드 + 템플릿 |
| Swift 6 strict concurrency 컴파일 이슈 | Low | Medium | actor 모델 이미 적용됨, OSC 제거로 감소 |
| 가상 MIDI 포트 타 앱 노출 | Medium | Low | Internal 접미어 + README 안내 + stop()에서 즉시 해제 |
| MCU 뱅킹 중 트랙 구조 변경 | Low | High | 트랙 수 검증 + 이름 검증 + 재뱅킹 (E15) |

## 11. Success Metrics

| Metric | Baseline (현재) | Target | Measurement Method |
|--------|----------------|--------|--------------------|
| 기능 커버리지 | ~35% (코드 리뷰 추정) | 93-95% | Appendix A 체크리스트 항목 실측 |
| 테스트 커버리지 | 0% | > 70% | swift test + lcov |
| 보안 취약점 | 1+ (AS injection) | 0 | 코드 리뷰 |
| MCU 양방향 상태 동기화 | 없음 | < 500ms | `logic_system("health")` latency 필드 |
| 빌드 성공 | Yes | Yes | swift build -c release |

## 12. Open Questions

- [x] ~~OQ-1: Logic Pro에서 MCU를 프로그래밍 방식으로 자동 등록할 수 있는가?~~ → **Phase 0 스파이크에서 실측 (2일)**. 수동이면 설치 가이드 + `logic_system("health")`에서 미등록 감지 + 등록 안내.
- [x] ~~OQ-2: MIDI Key Commands 프리셋을 .plist로 직접 설치할 수 있는가?~~ → **Phase 0 스파이크에서 실측**. 불가 시 Logic Pro 내 수동 Learn 가이드 제공.
- [ ] OQ-3: AX 트리 실측 결과에 따라 Accessibility 보조 채널의 scope 결정 — Phase 0 스파이크에서 실측
- [x] ~~OQ-4: Scripter JS 스크립트를 프로그래밍 방식으로 채널 스트립에 삽입할 수 있는가?~~ → **수동 설치 가정 (Risk: High/Impact: Low)**. Scripter 미설치 시 MCU fallback. 설치 가이드 + 템플릿 제공.

---

## Appendix A: Feature Coverage Checklist

> **주의**: 아래는 Phase 0 스파이크 실측 전 **예상치**. Phase 0 완료 후 OQ-1(MCU 등록), OQ-3(AX 트리) 결과에 따라 Supported 열을 확정하고 커버리지 비율을 재산정한다. 현 시점에서 93-95%는 목표이지 달성 확인이 아님.

| Category | Feature | Channel | Supported |
|----------|---------|---------|-----------|
| **Transport** | Play/Stop/Record | MCU | Yes |
| | Tempo read | MCU feedback | Yes |
| | Tempo set | MIDIKeyCmd | Yes |
| | Position/Goto | MCU Jog | Yes |
| | Cycle on/off | MCU | Yes |
| **Mixer** | Volume per channel | MCU fader | Yes |
| | Pan per channel | MCU V-Pot | Yes |
| | Mute/Solo/Arm | MCU buttons | Yes |
| | Send levels | MCU Send mode | Yes |
| | EQ control | MCU EQ mode | Yes |
| | Plugin parameters | MCU Plugin mode + Scripter | Yes |
| **Tracks** | Create (Audio/Instrument/Drummer) | MIDIKeyCmd | Yes |
| | Delete/Duplicate | MIDIKeyCmd | Yes |
| | Select | MCU Select button | Yes |
| | Automation mode | MCU Automation buttons | Yes |
| **MIDI** | Note/CC send | CoreMIDI | Yes |
| | Chord send | CoreMIDI | Yes |
| | Step Input | CoreMIDI + MIDIKeyCmd | Yes |
| **Editing** | Undo/Redo | MIDIKeyCmd | Yes |
| | Cut/Copy/Paste | MIDIKeyCmd | Yes |
| | Quantize | MIDIKeyCmd | Yes |
| | Transpose | MIDIKeyCmd | Yes |
| | Split/Join | MIDIKeyCmd | Yes |
| **Navigation** | View toggle (Mixer/PianoRoll/Score) | MIDIKeyCmd | Yes |
| | Goto bar | MCU Jog | Yes |
| | Markers | MIDIKeyCmd | Yes |
| | Zoom | MCU + MIDIKeyCmd | Yes |
| **Project** | Open/Save/Close | AppleScript (NSWorkspace) | Yes |
| | Bounce | MIDIKeyCmd | Yes |
| | Export | MIDIKeyCmd | Yes |
| **State Read** | Track names/states | MCU LCD feedback | Yes |
| | Mixer values | MCU fader/V-Pot feedback | Yes |
| | Transport state | MCU feedback | Yes |
| | Project info | AX supplementary | Partial |
| **NOT Supported** | Audio waveform edit | — | No (NG2) |
| | 3rd party plugin GUI | — | No (NG3) |
| | Live Loops | — | No (NG4) |
| | Score placement | — | No (NG5) |

**Supported: 35 / Total: 39 = ~90%. Partial 포함 시 ~93-95%.**
