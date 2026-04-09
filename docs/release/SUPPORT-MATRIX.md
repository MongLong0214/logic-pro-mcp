# Support Matrix

## Supported

| Area | Supported |
|:-----|:----------|
| macOS | 14+ |
| Logic Pro | 12.0.1+ |
| Architectures | arm64, x86_64 |
| MCP clients | Claude Code with local stdio server |

## Current Release Baseline

| Area | Baseline |
|:-----|:---------|
| Target release tag | `v2.0.0` |
| Primary validated local machine | `macOS 26.3` / `arm64` |
| Primary Logic Pro baseline | `12.0.1` (`6590`) |

## Validated Release Environments

| Environment | Validation Path |
|:------------|:----------------|
| macOS 15 / Apple Silicon | release workflow install validation |
| macOS 13 / Intel | release workflow install validation |
| Local dev machine | `swift build`, `swift test`, coverage gate, local validation baseline: `macOS 26.3` / `arm64` / `Logic Pro 12.0.1 (6590)` |

## Manual Validation Required

| Component | Reason |
|:----------|:-------|
| MIDI Key Commands | Logic Pro preset import cannot be introspected safely |
| Scripter | MIDI FX insertion cannot be introspected safely |

## Not Supported

- Non-macOS platforms
- macOS older than 14
- Logic Pro versions older than 12.0.1
