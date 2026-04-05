# Logic Pro MCP Server v2 — Setup Guide

Logic Pro 12.0.1 (Build 6590) 기준.

## 1. 빌드 + 설치

```bash
git clone git@github.com:MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
sudo cp .build/release/LogicProMCP /usr/local/bin/
```

## 2. Claude Code 등록

```bash
claude mcp add --scope user logic-pro -- LogicProMCP
```

## 3. Logic Pro MCU 설정

MCP 서버가 Logic Pro를 제어하려면 MCU (Mackie Control) 가상 장치를 등록해야 합니다.

1. Logic Pro 실행
2. **Logic Pro > 컨트롤 서피스 > 설정...** 메뉴 열기
3. **신규 > 설치** 선택
4. **Mackie Control** 선택 → **추가**
5. 추가된 장치의 **MIDI 입력**: `LogicProMCP-MCU-Internal` 선택
6. **MIDI 출력**: `LogicProMCP-MCU-Internal` 선택
7. 설정 창 닫기

> 참고: MCP 서버가 실행 중이어야 `LogicProMCP-MCU-Internal` 포트가 보입니다.

## 4. Key Commands 설치 (선택)

MIDI Key Commands를 사용하면 키보드 단축키를 MIDI CC로 트리거할 수 있습니다.

```bash
cd logic-pro-mcp
Scripts/install-keycmds.sh
```

설치 후 Logic Pro에서 수동으로 MIDI Learn 설정:
1. **Logic Pro > 키 명령 > 편집...** (⌥K)
2. CC 20-99 on Channel 16 → 해당 키 명령에 할당
3. 참조: `Scripts/keycmd-preset.plist`

## 5. Scripter 설치 (선택)

플러그인 파라미터를 CC 102-119로 제어하려면:

1. Logic Pro에서 대상 트랙 선택
2. **MIDI FX** 슬롯에 **Scripter** 추가
3. Script Editor에 `Scripts/LogicProMCP-Scripter.js` 내용 붙여넣기
4. **Run Script** 클릭

## 6. 확인

```bash
# 서버 직접 실행 (테스트)
LogicProMCP --check-permissions
# 출력: Accessibility: granted / Automation (Logic Pro): granted
```

macOS 권한 필요:
- **시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용** → 터미널/Claude 추가
- **시스템 설정 > 개인정보 보호 및 보안 > 자동화 > Logic Pro** → 허용

## 7. 제거

```bash
Scripts/uninstall.sh
```

또는 수동:
1. `sudo rm /usr/local/bin/LogicProMCP`
2. `claude mcp remove logic-pro`
3. Logic Pro > 컨트롤 서피스 > 설정 > MCU 장치 삭제
4. `Scripts/uninstall-keycmds.sh` (Key Commands 복원)
