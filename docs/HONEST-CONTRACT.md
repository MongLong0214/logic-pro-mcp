# Logic Pro MCP — Honest Contract

> v3.1.0+ 부터 모든 mutating operation이 준수하는 응답 계약.

## Why

GUI 자동화(AX, CoreMIDI, Scripter)는 본질적으로 비동기 + 검증 가능성이 제한적. v3.0.x에서는 "AX write 성공 = operation 성공"으로 가정했으나, 실제로는 write 리턴코드가 vacuously 성공이거나, Logic이 받았어도 실제 상태가 변경되지 않는 경우가 있음.

Honest Contract는 **클라이언트(LLM agent)가 성공/불확실/실패를 명확히 구분**할 수 있게 만든다.

## 3-State 규약

### State A — Confirmed Success
```json
{"success": true, "verified": true, "requested": <X>, "observed": <X>}
```
- AX write 성공 + read-back 으로 실제 상태 `<X>` 확인됨
- 클라이언트는 안심하고 다음 단계 진행

### State B — Uncertain Success
```json
{"success": true, "verified": false, "reason": "<enum>", "requested": <X>, "observed": null | <Y>}
```
- AX write 은 kAXErrorSuccess 또는 bytes 전송은 성공
- read-back 은 불가/타임아웃/불일치
- `reason` 값:
  - `echo_timeout_<ms>` — MCU feedback 윈도우 내 echo 없음 (± `2/16383` tolerance)
  - `readback_unavailable` — AX attribute 노출 안 됨 (Logic 버전/상태 이슈)
  - `readback_mismatch` — read 값(`observed`)이 요청값(`requested`)과 다름. `track.select`의 경우 다른 index가 선택됨.
  - `retry_exhausted` — retry 6회(100ms 간격, 총 600ms) 후 read-back 메타데이터가 surface 안 됨. `readback_mismatch`와 분리된다: 전자는 "값이 다름", 후자는 "값 자체가 surface 안 됨".
- 클라는 후속 검증 필요 (`logic://tracks` 조회 등)

### State C — Hard Failure
```json
{"success": false, "error": "<enum>", "axCode": <int?>, "hint": "<str?>"}
```
- AX write 자체가 kAXError 반환 또는 명시적 실패
- 재시도해도 상태 동일 → 다른 경로 필요
- `error` 값: `ax_write_failed`, `element_not_found`, `permission_denied`, `logic_not_running`, 등

## 어떤 op가 3-state를 반환하는가

v3.1.0 기준:
- `track.select`
- `track.set_instrument`
- `mixer.set_volume`, `mixer.set_pan`, `mixer.set_master_volume`
- `transport.set_cycle_range`

추가 예정(향후 릴리즈):
- 나머지 모든 `track.*`, `mixer.*`, `transport.*` mutating op

## State resource (query)

`logic://tracks`, `logic://library/inventory` 등 read-only resource는 3-state 대신:

```json
{"cache_age_sec": 12, "fetched_at": "2026-04-24T13:00:00Z", "data": [...]}
```

- `cache_age_sec`: 캐시 나이 (초). `0` = 방금 갱신.
- 클라가 필요 시 `refresh` 플래그로 재조회 요청 가능.

## 클라이언트 권장 패턴

```pseudo
result = call("track.set_instrument", {...})

if not result.success:
    # State C: hard fail, try alternate path
    abort_or_fallback(result.error)

elif result.verified:
    # State A: confirmed, proceed
    next_step()

else:
    # State B: uncertain
    if result.reason == "echo_timeout_500ms":
        sleep(0.5)
        actual = query("logic://tracks")
        if actual.matches(result.requested):
            proceed()
        else:
            retry_or_abort()
    # ... handle other reasons
```

## 개발자 가이드 (서버 측)

새 mutating op 추가 시:
1. AX write → 성공 여부 체크 (State C 분기)
2. write 성공 시 read-back attempt
3. read-back 성공 + 값 일치 → State A
4. read-back 실패/불일치 → State B with explicit `reason`
5. 모든 분기에서 `verified` 필드 반환 필수
6. `Tests/HonestContractTests.swift`에 3-state 별 케이스 추가

위반 사례:
- ❌ `return {"success": true}` — verified 없음
- ❌ `return {"verified": false}` — reason 없음
- ❌ `return {"success": false}` — error 없음
- ❌ read-back 호출 코드가 아예 없음 + verified:true

## 관련 릴리즈 노트

- **v3.1.0** — 초기 Honest Contract 도입. T2-T8 티켓 완료.
- **v3.1.0 Ralph-2 수정** — MCU `pollFaderEcho` stale-cache false-positive 차단 (send-time freshness stamp 도입), `track.select` mismatch → `readback_mismatch`로 분류(이전 `retry_exhausted`), `scan_library {mode:both}` → `lastPanelScan` 함께 갱신, `track.set_instrument`/`transport.set_cycle_range` State C `.error(...)` 래핑 통일, 리소스 envelope (`{cache_age_sec, fetched_at, data}` / `{source, root}`)를 CHANGELOG에 breaking change로 정직하게 표기.
