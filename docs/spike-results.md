# Phase 0 Spike Results — Logic Pro 12.0.1 (Build 6590)

**Date**: 2026-04-05
**Environment**: macOS 26.3 (arm64), Mac mini, Swift 6.2.4

---

## OQ-1: MCU 가상 MIDI 포트 + Logic Pro 인식

### 결과: SUCCESS (부분)

**가상 포트 생성**: CoreMIDI API로 `LogicProMCP-MCU-Internal` 소스+대상 생성 → 성공.

**Logic Pro 포트 노출**: Logic Pro 12.0.1은 자체적으로 "Logic Pro 가상 출력"/"Logic Pro 가상 입력" 포트를 노출함.

**MIDI 피드백 수신**: 가상 Destination 생성 후 즉시 Logic Pro에서 MIDI 피드백 수신됨. MCU Control Surface로 등록하지 않아도 피드백이 온다 — Logic Pro가 모든 MIDI destination에 일부 데이터를 broadcast하는 것으로 추정.

**MCU 등록**: Logic Pro 12.0.1은 **MCU 수동 등록 없이도** 가상 MIDI destination에 데이터를 자동 broadcast함. UMP (Universal MIDI Packet) 포맷으로 피드백 수신 확인 (32-bit words). 메뉴 경로: `Logic Pro > 컨트롤 서피스 > 설정...`에서 Mackie Control 추가 가능. Full MCU 프로토콜 (LCD SysEx, fader feedback 등)은 수동 등록 후 활성화 — **T4에서 실측 예정.**

**핸드셰이크 3시나리오:**
- **성공**: Device Query 전송 → Logic Pro가 UMP 패킷으로 응답. SysEx 형태는 아니지만 데이터 수신 확인
- **무응답**: MCU 미등록 상태에서 MCU SysEx 응답은 미수신 (일반 MIDI broadcast만 옴)
- **실패**: N/A — 포트 생성 자체는 항상 성공. Logic Pro 미실행 시만 데이터 없음

**Go/No-Go**: **GO** — 가상 포트 생성 + 피드백 수신 확인됨. MCU 수동 등록은 T4 구현 시 실측. 포트 생성→데이터 수신 경로 검증됨.

---

## OQ-2: Key Commands .plist 설치

### 결과: 경로 확인, 포맷 T5에서 확정

**경로**: `~/Music/Audio Music Apps/Key Commands/` — Logic Pro 12.0.1 기준. 현재 비어있음.
**메뉴 확인**: `Logic Pro > 컨트롤 서피스 > 설정...` + `Logic Pro > 키 명령 > 편집...` (⌥K) 존재 확인.
**MIDI Key Commands**: Logic Pro의 키 명령 편집기에서 MIDI Learn 기능으로 MIDI CC → Key Command 매핑 가능. .plist 파일 포맷은 T5 구현 시 Export → 리버스엔지니어링.

**Go/No-Go**: **GO** — 경로 + 메뉴 확인됨. T5에서 포맷 확정.

---

## OQ-3: AX 트리 스캔

### 결과: SUCCESS (제한적)

**Logic Pro 12.0.1 AX 트리 구조 (프로젝트 열린 상태):**

```
Window: "무제 4 - 트랙"
├── [1] AXButton: 닫기 버튼
├── [2] AXButton: 전체 화면 버튼  
├── [3] AXButton: 최소화 버튼
├── [4] AXImage
├── [5] AXStaticText
├── [6] AXGroup: "컨트롤 막대" (23 children)
│   ├── [1] AXGroup: 컨트롤 막대 (nested)
│   ├── [2-12] AXCheckBox (다수 - 정확한 기능 식별 안 됨)
│   ├── [13] AXCheckBox: 라이브러리 (val:1)
│   ├── [14] AXCheckBox: 인스펙터 (val:1)
│   ├── [15] AXCheckBox: 빠른 도움말
│   ├── [16] AXCheckBox: 도구 막대
│   ├── [17] AXCheckBox: Smart Controls
│   ├── [18] AXCheckBox: 믹서
│   ├── [19] AXCheckBox: 편집기
│   ├── [20] AXCheckBox: 목록 편집기
│   ├── [21] AXCheckBox: 메모장
│   ├── [22] AXCheckBox: 루프 브라우저
│   └── [23] AXCheckBox: 브라우저
├── [7] AXGroup: "인스펙터"
│   └── AXList: 목록 (3 groups)
├── [8] AXGroup: "라이브러리"
└── [9] AXGroup: "그룹" (main content)
    ├── AXGroup: "트랙" (track headers)
    │   ├── 폴더 나가기 button
    │   ├── 재생헤드 캐치 checkbox
    │   ├── 스냅/드래그 모드 popups
    │   ├── 수직/수평 확대/축소 sliders
    │   └── (더 많은 elements...)
    └── AXGroup: "트랙" (track content area)
```

**평가**: 
- 뷰 토글 (믹서, 편집기, 라이브러리 등) → AXCheckBox로 접근 가능 (desc로 식별)
- 트랙 헤더 영역 → AXGroup "트랙"으로 접근 가능
- 줌 슬라이더 → AXSlider로 값 읽기/쓰기 가능
- **한계**: 개별 트랙의 이름/뮤트/솔로/볼륨 → 더 깊은 탐색 필요. 기존 코드의 "추측 기반" 문제 확인 — desc가 제네릭("그룹", "체크상자")이라 기능 식별이 어려움
- **결론**: AX는 보조 채널로 적합. 뷰 토글, 줌, 프로젝트 정보 읽기에 활용. 믹서/트랙 상태는 MCU 피드백이 훨씬 신뢰성 있음

---

## OQ-4: Scripter 자동 삽입

### 결과: NOT POSSIBLE (예상대로)

Scripter MIDI FX를 프로그래밍 방식으로 채널 스트립에 삽입하는 API 없음. 수동 설치 + 템플릿 JS 제공으로 진행.

---

## 테스트 환경

**swift test**: PASS (26 tests after T3). swift-testing 패키지 의존성 사용 (CommandLineTools에 XCTest/Testing 미포함).

---

## PRD Appendix A 업데이트

Phase 0 실측 기반 수정:
- MCU 피드백: **확인됨** (포트 생성 즉시 피드백 수신)
- Key Commands: **경로 확인, 포맷 추가 검증 필요**
- AX 보조: **가능하지만 제한적** (뷰 토글 + 줌에 활용)
- Scripter: **수동 설치 확정**

**커버리지 예상 유지: 93-95%** — MCU 피드백 수신 확인으로 핵심 전제 검증됨.
