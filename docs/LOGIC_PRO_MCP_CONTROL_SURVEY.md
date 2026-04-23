# Logic Pro MCP 제어 경로 전수조사

작성일: 2026-04-21
대상 레포: `/Users/isaac/projects/logic-pro-mcp`
목적: Logic Pro MCP 서버를 만들기 위한 현실적인 제어 경로, 제약, 구현 우선순위를 한 문서로 정리한다.

---

## 0. 요약

핵심부터 말하면, Logic Pro에는 Ableton Live의 Python Remote Script나 REAPER의 ReaScript 같은 공개 DAW 객체 API가 사실상 없다.

그래서 안정적인 MCP 서버를 만들려면 단일 API에 올인하면 안 되고, 아래 조합으로 가는 것이 가장 현실적이다.

### 권장 조합
1. **Primary control**: `CoreMIDI + MCU/HUI + Controller Assignments`
2. **Secondary control**: `MIDI key-command assignments`
3. **Parameter layer**: `OSC Message Paths` 또는 `Controller Assignments`
4. **UI fallback**: `AXUIElement / Accessibility API`
5. **Content layer**: `MIDI / AAF / FCPXML import-export`
6. **In-project intelligence**: `Scripter` 또는 선택적 `AU/AUv3 bridge`
7. **Avoid**: `Logic Remote private protocol`, `.logicx` 내부 `ProjectData` 직접 수정

즉, **MCP의 핵심 백엔드는 MCU over CoreMIDI**로 잡고, **AX는 메뉴/다이얼로그/오류 감지 보조 수단**으로 한정하는 구조가 가장 강하다.

---

## 1. 이번 문서에 반영한 근거 범위

이 문서는 아래 세 축을 합쳐서 정리했다.

### A. Apple 공개 문서 기반 조사
- Logic Pro for Mac 사용자 가이드 12.2 계열
- Logic Pro 릴리스 노트 12.2 계열
- Core MIDI 문서
- Audio Unit / AUv3 문서
- Accessibility / AXUIElement 관련 문서

### B. 로컬 검증 결과
이 Mac에서 직접 확인한 사실:
- 설치 앱 경로: `/Applications/Logic Pro.app`
- 로컬 설치 버전: **Logic Pro 12.0.1**
- `NSAppleScriptEnabled = 1`
- 공개 `OSAScriptingDefinition` 키는 확인되지 않음
- 앱 번들 내부에서 공개 `*.sdef`, `*.scriptSuite`, `*.scriptTerminology`는 확인되지 않음
- AppleScript에서 `get version`, `count every document` 같은 표준 수준 질의는 일부 동작
- 트랙/리전 같은 풍부한 Logic 객체 모델은 AppleScript 수준에서 확인되지 않음
- `CFBundleURLTypes`에는 `applelogicpro`, `logicpro` 스킴이 존재
- `.logicx` 패키지 내부에는 `ProjectInformation.plist`, `MetaData.plist`, `DisplayState.plist`가 있으나 핵심 `ProjectData`는 공개 plist가 아니라 opaque binary data

### C. 기존 repo/운영 메모에서 확인된 사실
- **2026-04-08**: 제어 경로 자체는 살아 있어도 `project/info`, `transport/state`, `tracks`, `mixer` 읽기 결과는 stale 또는 불일치가 남아 truthfulness가 약했다.
- **2026-04-10**: `project.open` 실패의 일부는 verify false negative였고, open 검증식을 보강한 이력이 있다.
- **2026-04-12**: Logic UI/window state corruption 때문에 AppleScript document model과 AX/window model이 어긋난 사례가 있었다. 즉 권한 문제가 아니라 **런타임 UI 상태 불일치**가 실전 blocker가 될 수 있다.

이 세 가지는 MCP 설계에서 매우 중요하다. 특히 **쓰기 경로보다 읽기/검증 경로를 더 신중하게 설계해야 한다**는 점을 시사한다.

---

## 2. 가능한 제어 경로 전체 지도

| 경로 | 코드 레벨인가 | Logic 내부 객체 접근 | 양방향 상태 | 안정성 | MCP 적합도 |
|---|---|---:|---:|---:|---:|
| CoreMIDI + Controller Assignments | 예 | 제한적 | 제한적 | 높음 | 매우 좋음 |
| Mackie Control / HUI 에뮬레이션 | 예 | 믹서/트랜스포트 중심 | 좋음 | 중~높음 | 매우 좋음 |
| OSC Controller Assignments | 예 | 파라미터/컨트롤 중심 | 가능 | 중간 | 좋음 |
| MIDI Device Script / Lua / MDS | 예 | 컨트롤 서피스 매핑 | 가능 | 중간 | 좋음 |
| AXUIElement / Accessibility | 코드지만 UI 계층 | 보이는 UI 위주 | 가능 | 중간~낮음 | 필수 보조 |
| AppleScript / JXA / Apple Events | 예 | 거의 없음 | 거의 없음 | 낮음 | 실행/열기 정도 |
| Logic Remote 프로토콜 | 사설/비공개 | 많아 보임 | 좋을 가능성 | 낮음 | 비추천 |
| Scripter JavaScript | Logic 내부 코드 | MIDI/호스트 타이밍 | 제한적 | 높음 | 음악적 작업에 좋음 |
| Audio Unit / AUv3 플러그인 | 예 | 플러그인 내부 | 호스트 정보 제한적 | 높음 | 브리지로 좋음 |
| `.logicx` 파일 직접 수정 | 코드 | 위험 | 없음 | 낮음 | 비추천 |
| MIDI / AAF / FCPXML import-export | 예 | 오프라인 | 없음 | 높음 | 생성/분석에 좋음 |

정리하면:
- **실제 제어**는 `CoreMIDI/MCU/HUI`가 중심
- **상태 추정과 보강**은 `MCU feedback + AX`
- **콘텐츠 생성과 교환**은 `MIDI/AAF/FCPXML + Scripter/AU`
- **AppleScript/JXA는 주력 백엔드가 아님**

---

## 3. 1순위: CoreMIDI + Logic Controller Assignments

Apple의 Core MIDI는 macOS 앱이 가상 MIDI source/destination을 만들고 장치처럼 통신할 수 있게 해준다. Logic Pro는 Controller Assignments를 통해 MIDI 입력을 Logic 기능, 채널 스트립, 플러그인 파라미터, 키 커맨드 등에 매핑할 수 있다.

### 이 경로가 강한 이유
- 로컬 가상 포트로 안정적으로 붙일 수 있음
- UI 트리보다 버전 변화에 덜 깨짐
- transport, mixer, smart controls, plugin parameter 제어에 강함
- MCP의 tool abstraction과 잘 맞음

### 가능한 작업
| 작업 | 가능성 |
|---|---:|
| Play / Stop / Record / Cycle | 높음 |
| Mute / Solo / Arm / Select Track | 높음 |
| Volume / Pan / Send Level | 높음 |
| Smart Controls 제어 | 높음 |
| 플러그인 파라미터 제어 | 중~높음 |
| Automation mode 변경 | 중~높음 |
| Bounce/export dialog 자동화 | 낮음, AX 필요 |
| Region 생성/이동/분할/편집 | 직접 API 없음 |
| 트랙/리전 목록 구조적 조회 | 제한적 |

### MCP 구현 형태 예시
```json
{
  "tool": "logic.transport.play"
}
```
내부에서는 예를 들어:
- virtual MIDI 포트로 Note/CC/SysEx 송신
- Logic Controller Assignments가 이를 Play에 매핑

### 설계 함의
- **쓰기 명령은 강함**
- **고수준 상태 읽기에는 약함**
- 따라서 상태는 `MCU feedback`, `AX visible state`, `project/file metadata`, `internal cache`를 조합해야 한다.

---

## 4. 1.5순위: Mackie Control / HUI 에뮬레이션

단순 MIDI learn보다 더 강한 방식은 MCP 서버가 가상 `Mackie Control Universal` 또는 `HUI` 장치처럼 행동하는 것이다. Logic Pro는 Mackie Control/HUI를 공식 control surface 흐름 안에서 지원한다.

### 장점
- 양방향성
- fader position, LED state, scribble strip/display text 피드백 가능
- 트랙 뱅킹, 조그휠, 플러그인 편집, 믹서 제어에 강함

### 좋은 MCP 도구 예시
- `logic.transport.play()`
- `logic.transport.stop()`
- `logic.transport.record()`
- `logic.mixer.set_fader(track=3, db=-6.0)`
- `logic.mixer.set_pan(track=3, pan=0.2)`
- `logic.track.bank_left()`
- `logic.track.bank_right()`
- `logic.track.select(index=5)`
- `logic.plugin.next_parameter()`
- `logic.plugin.set_current_parameter(value=0.73)`

### 설계 함의
- **가장 실용적인 1차 백엔드 후보**
- 일반 Controller Assignments보다 상태 피드백을 다루기 쉽다.
- 특히 `track name`, `selected bank`, `mute/solo/fader state` 추정에 유리하다.

---

## 5. OSC: 유용하지만 공개 객체 API는 아님

Logic Pro는 Controller Assignments의 OSC Message Paths를 지원한다. 공개 문서 기준으로 현재 OSC 구현은 UDP와 IPv4 중심이다.

### 좋은 점
- MIDI보다 메시지 표현이 읽기 쉬움
- 값, 터치/릴리즈, 라벨 피드백을 설계할 수 있음
- 나중에 iPad/Web UI/원격 컨트롤러와 붙이기 좋음

### 한계
- Logic에 범용 REST/OSC API가 있는 것이 아님
- Control Surface / Controller Assignments 맥락에서 설정해야 함
- 무설정 상태에서 `/logic/play` 같은 일반 API를 기대하면 안 됨

### 추천 용도
| 용도 | 평가 |
|---|---:|
| 커스텀 믹서/플러그인 파라미터 제어 | 좋음 |
| MCP와 Logic 간 네트워크 브리지 | 좋음 |
| 상태 피드백 | 가능 |
| 완전 자동 프로젝트 편집 API | 아님 |

### 설계 함의
- 로컬 전용이면 CoreMIDI가 더 단순할 수 있다.
- 장기적으로 remote control/UI 확장을 생각하면 OSC 레이어를 별도로 설계할 가치는 있다.

---

## 6. MIDI Device Script / MDS / Lua / Control Surface Plug-in

Logic의 control surface는 MIDI Device Script/MDS/Lua 기반 매핑 또는 전용 control surface profile 형태로 확장될 수 있다.

### 의미
단순히 “MIDI 메시지를 던지는 앱”보다 한 단계 나아가, MCP 전용 컨트롤러를 Logic 안에서 정식 control surface처럼 취급하게 만들 수 있다.

### 가능한 전략
```text
MCP Logic Control Surface
 - virtual MIDI input
 - virtual MIDI output
 - MDS/Lua profile or MCU profile
 - Logic Controller Assignments preset
```

### 설계 함의
- binary MDP보다는 `MDS/Lua`, `MCU/HUI`, `Controller Assignments preset` 쪽이 장기 유지보수에 유리하다.
- 초기 MVP는 **MCU/HUI 에뮬레이션 + preset**으로 가고, 필요 시 MDS/Lua 확장으로 가는 편이 안전하다.

---

## 7. AXUIElement / Accessibility API: 보조지만 거의 필수

AXUIElement는 assistive application이 macOS 앱의 접근성 객체와 통신하고 제어할 수 있게 하는 공식 API다.

### MCP에서 AX가 필요한 이유
MIDI/MCU/OSC만으로는 아래가 부족하다.

| 작업 | AX 필요성 |
|---|---:|
| Bounce dialog 열기/옵션 채우기 | 높음 |
| Export / Import 메뉴 실행 | 높음 |
| Preferences 변경 | 높음 |
| Project settings dialog 조작 | 높음 |
| 현재 열린 프로젝트 이름 읽기 | 중간 |
| 플러그인 창 UI 읽기 | 중~높음 |
| 메뉴 enabled/disabled 상태 확인 | 높음 |
| 오류/경고 modal 감지 | 매우 높음 |

### 중요한 원칙
AX는 “Logic 객체 API”가 아니라 “Logic UI API”다.

따라서 AX는 아래 용도로 제한하는 것이 좋다.
1. 메뉴 실행
2. 다이얼로그 자동 입력
3. 에러/모달 감지
4. 현재 보이는 상태 읽기
5. MIDI/MCU로 불가능한 export/import류 보조

### 권한
- Accessibility permission 필요
- 배포형 앱이면 사용자가 System Settings에서 권한 허용 필요

### Swift 최소 형태 예시
```swift
import ApplicationServices

func requestAccessibilityPermission() -> Bool {
 let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
 let options = [key: true] as CFDictionary
 return AXIsProcessTrustedWithOptions(options)
}
```

### repo 맥락에서 특히 중요한 점
기존 운영 메모상 Logic은 **문서 모델과 UI/window 모델이 어긋나는 경우가 있었다.**
따라서 AXProvider는 단순 action executor가 아니라 다음을 반드시 포함해야 한다.
- window observer
- modal detector
- timeout/retry
- focused window 검증
- visible state extractor
- stale cache 감지

---

## 8. AppleScript / JXA / Apple Events: 주력으로 기대하지 말 것

일반적으로 AppleScript/JXA가 강하려면 앱이 의미 있는 scripting dictionary(.sdef)를 제공해야 한다.

### 로컬 검증 결론
- `NSAppleScriptEnabled = 1`
- 표준 Apple Event 수준은 일부 동작
- 공개 `sdef`는 확인되지 않음
- Logic 전용 트랙/리전/믹서 객체 모델은 확인되지 않음

즉 결론은:
- **앱 실행 / activate / 파일 열기 / quit 정도는 기대 가능**
- **트랙/리전/플러그인/프로젝트 구조 제어는 기대하면 안 됨**

### 쓸 수 있는 것
- Logic 실행
- `.logicx` 파일 open
- 앱 activate
- quit
- Finder/NSWorkspace 기반 open

### 기대하면 안 되는 것
- `tracks[3].volume = -6`
- `selectedRegion.start = bar 17`
- `create software instrument track`
- `insert plugin`
- `bounce with options`

### 설계 함의
- AppleScript/JXA는 **주력 provider가 아니라 보조 utility**로 취급
- `project.open`, `app.activate`, `document count` 확인 정도로 제한
- UI scripting이 필요하면 차라리 Swift/PyObjC AX 경로가 낫다

---

## 9. Logic Remote 프로토콜: 연구용은 가능, 제품 백엔드는 비추천

Logic Remote는 공식 앱이지만, 그 프로토콜은 공개 개발자 API로 문서화되어 있지 않다.

### 판단
| 용도 | 평가 |
|---|---:|
| 개인 연구용 | 가능 |
| 상용/공개 MCP | 비추천 |
| 업데이트 내성 | 낮음 |
| 정책/배포 리스크 | 있음 |

### 설계 함의
- 기능은 매력적일 수 있지만, 유지보수와 배포 안정성을 생각하면 **MCU/HUI + OSC + AX** 조합이 더 낫다.

---

## 10. Scripter JavaScript: Logic 내부 MIDI/타이밍 브리지

Scripter는 Logic 내부에서 JavaScript로 MIDI를 생성/변환하고 host timing 정보를 읽는 MIDI FX 플러그인이다.

### 좋은 점
- transport playing, tempo, meter, cycle 상태 일부 접근 가능
- MIDI note/CC 생성 가능
- 프로젝트 내부에 저장되는 “음악적 자동화 엔진” 역할 가능

### 잘 맞는 용도
- 코드 진행 생성
- 드럼 패턴 생성
- MIDI transform
- 템포 기반 generative behavior
- host timing-aware MIDI logic

### 한계
- 트랙 생성 불가
- 리전 이동 불가
- 플러그인 삽입 불가
- bounce/export 불가
- 파일/프로세스/네트워크 제어 불가

### 설계 함의
- Scripter는 **MCP의 외부 제어 백엔드**라기보다 **프로젝트 내부 지능 레이어**에 적합하다.
- “AI가 음악을 만들고 Logic 안에서 바로 반응한다”는 방향이면 매우 강하다.

---

## 11. Audio Unit / AUv3 플러그인: 장기적으로 강한 내부 브리지 후보

Logic은 Audio Unit/AUv3 플러그인을 정식 지원한다. 따라서 `MCP Bridge AU` 같은 구조가 가능하다.

```text
Logic Pro project
 -> MCP Bridge AU / MIDI FX / Instrument
 -> local IPC / socket / XPC
 -> MCP Server
```

### 가능한 일
- 오디오/MIDI 처리
- 플러그인 파라미터를 MCP로 노출
- Logic automation lane과 MCP parameter 연결
- host tempo/transport 반응형 생성기
- 프로젝트 내부에 저장되는 브리지 엔드포인트

### 못 하는 일
- 새 트랙 생성
- 리전 이동
- 다른 채널에 플러그인 삽입
- Logic 프로젝트 객체 직접 조작

### 설계 함의
- **실시간 생성/처리/반응형 워크플로**에는 강력함
- 그러나 DAW 객체 API 대체재는 아님
- 장기 로드맵에선 유력하지만, 초기 MCP 핵심 백엔드로는 `MCU/HUI`가 더 현실적임

---

## 12. 파일 기반 접근: MIDI / AAF / Final Cut Pro XML

`.logicx` 내부 `ProjectData`를 직접 조작하는 건 피하는 게 좋다. 공개 편집 포맷이 아니기 때문이다.

### 대신 공식 교환 포맷을 쓸 것

#### Standard MIDI File
좋은 용도:
- 코드 진행 생성
- 드럼 패턴 생성
- 베이스라인 생성
- MIDI CC automation 후보 생성

#### Final Cut Pro XML
좋은 용도:
- 오디오 stem 기반 프로젝트 교환
- 포스트 프로덕션 워크플로
- volume/pan automation 포함 교환

#### AAF
좋은 용도:
- DAW 간 오디오 세션 교환
- 멀티트랙 오디오 arrangement 초안
- 포스트/세션 handoff

### 설계 함의
MCP 쪽에선 아래처럼 추상화하면 된다.
- `logic.create_midi_file(...)`
- `logic.project.import_midi(path)`
- `logic.project.import_audio(path)`
- `logic.project.export_aaf(path)`
- `logic.project.export_fcpxml(path)`

실제 import/export 실행은 대부분 AX나 key command 보조가 필요하다.

---

## 13. Synchronization: MTC / MIDI Clock / MMC / Ableton Link

동기화는 직접 제어와는 다르지만, 외부 앱/장치와 Logic을 맞출 때 중요하다.

| 프로토콜 | MCP 용도 |
|---|---:|
| MMC | transport sync/control |
| MTC | 타임코드 기반 follow |
| MIDI Clock | 외부 장치 tempo sync |
| Ableton Link | 네트워크 beat/tempo/phase sync |
| MIDI CC/Note | 실제 명령 실행 |
| MCU/HUI | 실제 컨트롤 서피스 제어 |

### 설계 함의
- 동기화는 MCP의 1차 핵심 범위는 아니지만, 향후 multi-app/music system orchestration에 유용하다.

---

## 14. 권한과 배포 이슈

| 기능 | 필요한 권한/설정 |
|---|---:|
| CoreMIDI 가상 포트 | 보통 별도 TCC 없음 |
| AXUIElement | Accessibility permission |
| CGEvent 키 입력 주입 | Accessibility/Input 관련 권한 가능 |
| Apple Events / osascript | Automation permission, usage description |
| OSC/Bonjour/local network | Local Network privacy 고려 |
| AUv3 | code signing, extension validation |
| MCP stdio server | 비교적 단순 |
| MCP HTTP/WebSocket server | local network/firewall 고려 |

### 설계 함의
- CLI만 돌릴 때와, 메뉴바 앱/helper까지 포함할 때의 배포 요구사항이 달라진다.
- OSC/Bonjour를 쓸 경우 local network privacy 테스트가 필요하다.

---

## 15. 권장 MCP 아키텍처

```text
logic-pro-mcp
 ├─ MCP protocol layer
 ├─ Command planner
 ├─ State cache
 ├─ Providers
 │ ├─ CoreMIDIProvider
 │ │ ├─ virtual MIDI source
 │ │ ├─ virtual MIDI destination
 │ │ ├─ MCU/HUI encoder/decoder
 │ │ └─ simple CC/Note sender
 │ ├─ OSCProvider
 │ │ ├─ UDP IPv4 sender
 │ │ ├─ feedback listener
 │ │ └─ assignment profile
 │ ├─ AXProvider
 │ │ ├─ menu executor
 │ │ ├─ dialog handler
 │ │ ├─ window observer
 │ │ └─ visible state reader
 │ ├─ FileProvider
 │ │ ├─ MIDI writer
 │ │ ├─ audio/stem manager
 │ │ ├─ FCPXML/AAF helper
 │ │ └─ import/export orchestration
 │ └─ PluginBridgeProvider
 │   ├─ Scripter profile
 │   └─ optional AUv3 bridge
 └─ Logic profiles
   ├─ Logic 12.2 English AX map
   ├─ Logic 12.x key command map
   ├─ Controller assignment preset
   └─ MCU/HUI profile
```

### Provider 우선순위 예시

#### transport.play
1. MCU transport command
2. MIDI key-command assignment
3. AX menu/key command
4. CGEvent fallback

#### mixer.set_volume
1. MCU fader
2. OSC/controller assignment
3. MIDI CC assignment
4. AX fallback

#### project.bounce
1. AX menu/dialog automation
2. key command + AX dialog
3. unsupported

---

## 16. MCP tool 설계 예시

### Transport
- `logic.transport.play()`
- `logic.transport.stop()`
- `logic.transport.toggle_play()`
- `logic.transport.record()`
- `logic.transport.set_cycle(enabled: boolean)`
- `logic.transport.go_to_bar(bar: number)`

구현: MCU/HUI 또는 key-command MIDI. 위치 입력은 AX나 key command dialog 보조 가능.

### Mixer
- `logic.mixer.set_volume(track: number | string, db: number)`
- `logic.mixer.set_pan(track: number | string, pan: number)`
- `logic.mixer.mute(track, enabled)`
- `logic.mixer.solo(track, enabled)`
- `logic.mixer.arm(track, enabled)`
- `logic.mixer.select_track(track)`
- `logic.mixer.bank(offset)`

구현: MCU 우선. 트랙 이름 기반 탐색은 `scribble strip feedback` 또는 `AX visible track parsing` 필요.

### Plugin / Smart Controls
- `logic.smart_control.set(name_or_index, value)`
- `logic.plugin.focused.set_parameter(index, value)`
- `logic.plugin.focused.next_parameter()`
- `logic.plugin.focused.bypass(enabled)`

구현: Controller Assignments / OSC / MCU plugin edit. 플러그인 삽입은 AX 필요.

### Project I/O
- `logic.project.open(path)`
- `logic.project.import_midi(path)`
- `logic.project.import_audio(path)`
- `logic.project.export_aaf(path)`
- `logic.project.export_fcpxml(path)`
- `logic.project.bounce(path, format, range)`

구현: 파일 open은 NSWorkspace/Apple Event 가능. import/export/bounce는 AX가 현실적.

### Creative generation
- `logic.create_midi_region_from_prompt(prompt, track)`
- `logic.write_chord_progression(track, bars, style)`
- `logic.generate_drum_pattern(track, bars, genre)`

구현: MCP가 MIDI 파일 생성 후 Logic import, 또는 Scripter/AU bridge 사용.

---

## 17. 피해야 할 길

### 1) `.logicx` 내부 `ProjectData` 직접 수정
- 공개 포맷 아님
- 버전업에 취약
- 데이터 손상 가능성 큼

### 2) Logic Remote 프로토콜 올인
- 공개 API 아님
- 유지보수 리스크 큼

### 3) 순수 AX/키보드 자동화만으로 전체 MCP 구현
- 빠른 프로토타입은 가능
- 하지만 언어 설정, 창 배치, Logic 버전, 모달 상태에 취약
- AX는 보조 수단으로만 유지해야 함

### 4) AppleScript/JXA에 과도한 기대
- Logic은 이 경로가 약함
- 실행/열기/activate 수준으로 제한하는 것이 맞음

---

## 18. 실제 구현 순서 추천

### 1단계: CoreMIDI virtual port + 기본 transport
- virtual MIDI source/destination 생성
- Logic Controller Assignments preset 제공
- `play / stop / record / cycle / metronome / count-in`

### 2단계: MCU 에뮬레이션
- 가상 Mackie Control 등록
- fader / pan / mute / solo / select / bank / display feedback 확보
- 여기까지 되면 MCP가 세션 상태를 어느 정도 추정 가능

### 3단계: AXProvider
- bounce / export / import / preferences / project settings
- modal error handling
- 좌표 클릭 대신 AX menu item / form field 기반 구현

### 4단계: FileProvider
- MIDI 생성/import
- audio stem 관리
- FCPXML / AAF export/import

### 5단계: Scripter 또는 AU Bridge
- 음악 생성
- 실시간 MIDI 처리
- host timing 기반 in-project intelligence

---

## 19. repo-specific 시사점

이 레포의 과거 운영 이력을 기준으로 보면, 앞으로 특히 조심해야 할 부분은 아래다.

### A. 쓰기보다 읽기 검증이 더 어렵다
transport나 track/mixer command가 실행되더라도, readback이 stale이면 MCP는 거짓 완료를 말하게 된다. 따라서:
- command success와 state verification을 분리할 것
- verification timeout과 stale cache 감지를 별도 상태로 둘 것
- `attempted but unverified` 상태를 정식 결과 타입으로 둘 것

### B. `project.open`류는 false positive를 강하게 경계해야 한다
- 성공 응답만 믿지 말고 실제 front document / document count / visible window를 교차 검증할 것
- AppleScript model, AX window model, internal cache를 분리할 것

### C. UI/window corruption 대응이 필요하다
- Logic runtime이 꼬이면 AX 기준으론 window 0, AppleScript 기준으론 document 1 같은 불일치가 생길 수 있다.
- 따라서 health check는 아래처럼 다층으로 둘 것:
  - process alive
  - app frontmost
  - document count
  - front document path
  - AX focused window
  - main window bounds
  - MCU connected / MIDI device registered
  - modal present 여부

---

## 20. 최종 결론

Logic Pro MCP를 만든다면 “정답 API”는 없다.

하지만 현실적인 정답에 가장 가까운 조합은 분명하다.

### 최종 추천
1. `CoreMIDI virtual device`
2. `Mackie Control / HUI emulation`
3. `Logic Controller Assignments + key commands`
4. `OSC Message Paths where useful`
5. `AXUIElement for menus/dialogs/visible state`
6. `MIDI / AAF / FCPXML for file-level exchange`
7. `Scripter / AU for in-project intelligence`

### 기본 백엔드 권장안
- **Primary control**: MCU over CoreMIDI
- **Secondary control**: MIDI key-command assignments
- **Parameter layer**: OSC or Controller Assignments
- **UI fallback**: AXUIElement
- **Content layer**: MIDI / FCPXML / AAF + optional Scripter/AU bridge
- **Avoid**: private Logic Remote protocol, direct `.logicx` mutation

이 방향이 Logic 업데이트에도 비교적 강하고, MCP tool abstraction과도 가장 잘 맞는다.

---

## 21. 참고 근거

### 로컬 검증
- `/Applications/Logic Pro.app`
- `/Users/isaac/Documents/Logic/LoFi-MCP-Demo.logicx`
- AppleScript/Info.plist/URL scheme/패키지 구조 확인

### 프로젝트 운영 메모
- `memory/2026-04-08.md`
- `memory/2026-04-09.md`
- `memory/2026-04-10.md`
- `memory/2026-04-12.md`

### 공개 문서
- Logic Pro User Guide for Mac
- Audio MIDI Setup / MIDI devices
- Apple Core MIDI documentation
- Apple Audio Unit v3 Plug-Ins documentation
- Apple Accessibility / AXUIElement documentation
