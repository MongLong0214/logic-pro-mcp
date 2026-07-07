# T10: Static Version Marker / SemanticVersion

**Priority**: P1
**Status**: Todo
**Depends On**: T3, T8

## Objective

Reduce `strings` false positives by embedding a static LogicProMCP version marker and parsing it with a real SemanticVersion parser.

## Acceptance Criteria

- [ ] Release binary embeds a unique marker such as `LOGIC_PRO_MCP_VERSION=<semver>`.
- [ ] Static sniff prefers the marker over generic semver strings.
- [ ] SemanticVersion parser rejects invalid values and compares prerelease/build metadata intentionally.
- [ ] Candidate version evidence distinguishes marker match, marker missing, and ambiguous fallback.
- [ ] Existing stale-install warning remains covered.

## Red Tests

- `semanticVersionParsesMajorMinorPatch`
- `semanticVersionRejectsInvalid`
- `staticVersionSniffPrefersMarker`
- `staticVersionSniffAmbiguousWithoutMarkerIsIndeterminate`
- `installInventoryWarnsOnMarkerMismatch`

## Implementation Boundary

Likely files: `ServerConfig.swift` or build metadata file, `SetupDoctor+Versioning.swift`, `SetupDoctor+InstallChecks.swift`, release/version tests.

## QA Gate

Build release, run static sniff against `.build/release/LogicProMCP`, and verify marker evidence.
