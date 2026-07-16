# #367 B4 게이트 무결성 설계 판정

## 결론

**권고: (d) CI가 immutable full commit SHA로 checkout한 독립 verifier를 유일한 authoritative promotion gate로 사용한다.**

단, verifier만 별도 실행해서는 부족합니다. 현재 candidate는 qualification 단계에서 private signing key를 직접 받습니다. 따라서 독립성을 제대로 확보하려면 pinned tool이 다음 둘을 함께 소유해야 합니다.

1. qualification bundle 전체 promotion 정책 검증
2. 검증 후 provenance 서명 및 release 단계의 서명 검증

현 candidate의 `--verify-promotion`은 로컬 진단용으로만 남기고 release 승인 권한에서는 제외합니다.

## 코드로 증명된 현재 신뢰 경계

### 1. Candidate가 자신의 release 여부를 결정한다

Release workflow는 candidate SHA를 계산한 뒤 바로 candidate를 실행합니다.

- candidate 실행: [release.yml:172](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/.github/workflows/release.yml:172)
- 실제 self-verification: [release.yml:188](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/.github/workflows/release.yml:188)
- 뒤의 `trusted-provenance-verify`는 파일·환경변수 존재만 확인: [release.yml:196](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/.github/workflows/release.yml:196)

`--verify-promotion`의 exit code를 결정하는 로직도 전부 candidate 안에 있습니다.

- CLI dispatch: [QualificationRunner.swift:178](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:178)
- attestation decode, `PromotionGate`, evidence binding, provenance 검증, 자기 실행파일 SHA 확인: [QualificationRunner.swift:829](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:829)
- 정책 판단 본체: [PromotionGate.swift:28](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/PromotionGate.swift:28)

따라서 candidate가 `--verify-promotion`에서 항상 0을 반환하면 release workflow는 이를 구별할 독립 관찰자가 없습니다.

### 2. “Candidate가 private key를 못 가진다”는 전제는 코드상 거짓이다

Release job에는 public key만 전달되는 것은 맞습니다. 하지만 qualification 과정에서는 candidate 프로세스가 private key를 직접 읽습니다.

- candidate가 환경에서 signing key를 로드: [QualificationRunner.swift:228](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:228)
- private key 파싱: [QualificationRunner.swift:1723](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:1723)
- candidate가 provenance에 직접 서명: [QualificationRunner.swift:1745](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:1745)

키를 제거하는 것은 candidate가 구동하는 하위 MCP subprocess 환경뿐입니다. qualification runner 자체에는 이미 키가 들어왔습니다. 테스트도 이 좁은 성질만 검증합니다: [QualificationRunnerTests.swift:346](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Tests/LogicProMCPTests/QualificationRunnerTests.swift:346).

저장소에서 production key 생성·회전·provisioning 구현은 발견되지 않았습니다. 테스트만 고정 32-byte raw key를 생성합니다: [QualificationRunnerTests.swift:2236](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Tests/LogicProMCPTests/QualificationRunnerTests.swift:2236).

### 3. 독립 서명 검증만 추가해도 전체 gate는 독립화되지 않는다

서명 대상은 `QualificationProvenanceRecord`입니다: [ReleaseQualificationAttestation.swift:453](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/ReleaseQualificationAttestation.swift:453).

Cases와 waivers는 서명 입력에 직접 포함되지 않습니다. Manifest digest를 통해 간접 연결되지만, 그 연결을 실제로 확인하는 로직도 candidate가 실행합니다: [QualificationRunner.swift:1165](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:1165).

또한 `qualify`는 실패 case가 존재하더라도 provenance를 서명하며, 예외만 없으면 CLI exit 0을 반환합니다.

- 무조건 서명·attestation 작성: [QualificationRunner.swift:766](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:766)
- `qualify` 완료 시 무조건 exit 0: [QualificationRunner.swift:181](/Users/isaac/projects/logic-pro-mcp-adr001-remediation/Sources/LogicProMCP/Qualification/QualificationRunner.swift:181)

따라서 signature-valid는 “promotion-valid”가 아닙니다.

## 옵션 비교

| 옵션 | 독립 신뢰성 | 구현·운영 비용 | 이번 릴리스 적합성 | 판정 |
|---|---:|---:|---:|---|
| (a) 이전 stable binary | 중간 | 중간~높음 | 부적합 | 현재 stable `v3.11.0`에는 `--verify-promotion`이 없고, 현 verifier는 verifier 자신의 executable SHA를 candidate SHA와 비교하므로 다른 binary 검증기로 사용할 수 없음 |
| (b) 별도 script/tool | 낮음~중간 | 중간~높음 | 조건부 | candidate checkout에 함께 있으면 candidate commit이 tool과 workflow를 동시에 바꿀 수 있어 독립 아님. Immutable pin을 추가하는 순간 사실상 (d) |
| (c) R-PROV를 서명 신뢰로 축소 | 낮음 | 낮음 | 위험 수용용만 가능 | public key가 secret이라는 사실은 검증 실행을 강제하지 않음. 더구나 candidate가 qualification private key를 받으므로 “candidate 위조 불가” 전제도 성립하지 않음 |
| (d) 별도 pinned verifier checkout | 높음 | 초기 중간, 이후 낮음~중간 | 적합 | candidate를 실행하지 않고 bytes로만 검증하며, verifier source와 policy를 immutable SHA로 고정할 수 있음 |

## 최소 실효 설계

### 독립 verifier

기존 Swift/CryptoKit을 사용하는 작은 standalone tool 하나를 두 모드로 운용합니다. 새 crypto dependency는 필요 없습니다.

- `sign` 모드: qualification host에서 unsigned bundle을 전체 검증한 후 provenance에 서명
- `verify` 모드: release CI에서 candidate와 bundle을 읽기 전용 검증
- candidate `LogicProMCP`는 signing key를 절대 받지 않음
- verifier는 candidate를 실행하지 않고 binary bytes의 SHA-256만 계산

필수 검증 범위:

- Ed25519 signature, key ID
- candidate binary SHA
- release tag/version
- `provenance.commitSHA == GITHUB_SHA`
- signed manifest digest
- case-manifest/attestation equality
- 모든 evidence digest와 schema
- required artifacts
- waiver, operation, matrix, semantic-readback 등 현재 `PromotionGate` 전체 정책

서명만 독립 검증하고 `PromotionGate`는 candidate에 남기는 절충안은 B4를 닫지 못합니다.

### Release workflow

1. Candidate build/package
2. 외부 bundle 다운로드 및 archive SHA 검증
3. verifier를 별도 경로에 full 40-character commit SHA로 checkout
4. pinned source로 verifier build
5. `trusted-verifier verify --candidate LogicProMCP --bundle ... --release-version ... --expected-commit "$GITHUB_SHA"` 실행
6. 성공할 때만 GitHub Release 생성

Candidate의 `./LogicProMCP --verify-promotion`은 release 판정에서 제거하거나 non-authoritative 진단으로만 유지합니다.

### Pin 보호

같은 저장소의 이전 commit을 pin하려면 최소 두 commit이 필요합니다.

1. verifier bootstrap commit을 별도 리뷰·merge
2. 후속 release commit에서 그 immutable SHA를 pin

Verifier pin이나 호출을 candidate workflow가 임의로 제거할 수 있으면 독립성이 다시 약화됩니다. 따라서 verifier/pin 변경에는 CODEOWNERS 또는 별도 protected reusable workflow가 필요합니다. 별도 저장소에 pinned reusable workflow를 두면 가장 강한 분리가 됩니다.

## 필수 부정 검증

독립 gate는 최소한 다음을 거부해야 합니다.

- candidate의 `--verify-promotion`이 무조건 0을 반환하는 경우
- 올바르게 서명됐지만 failed case가 포함된 attestation
- wrong public key 또는 foreign signing key
- binary SHA, release version, `GITHUB_SHA` 불일치
- manifest/case/evidence 변조
- required artifact 누락
- verifier step의 `continue-on-error`, 우회 가능한 `if`, mutable ref 사용

## CTO 결정

**(d) 채택.** Pinned independent verifier가 전체 promotion 정책을 실행하고 private key custody까지 candidate 밖으로 이동해야 B4가 실제로 닫힙니다.

(c)는 “candidate-enforced verification of externally supplied provenance”로 명칭을 낮추는 위험 수용안일 뿐, `trusted independent provenance`나 self-verification 결함의 해소안은 아닙니다.

읽기 전용·worktree 내부 제한 때문에 지정된 `/private/tmp/.../c2-verifier-design.md`에는 쓰지 않았으며, 코드 수정·빌드·테스트도 수행하지 않았습니다. 현재 HEAD는 `7ac8812274320b4cc1c0738eab08f154ccc58a61`; B4 결론에 영향을 주지 않는 관련 파일의 미커밋 변경이 존재합니다.