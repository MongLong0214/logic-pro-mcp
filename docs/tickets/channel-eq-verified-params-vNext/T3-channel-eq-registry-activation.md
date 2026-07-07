# T3: Channel EQ Registry Activation

**PRD Ref**: `PRD-channel-eq-verified-params-vNext` §6
**Priority**: P0 after census PASS
**Status**: Blocked
**Depends On**: T0 or T1 or T2 PASS

## Objective

Activate only census-proven Channel EQ parameters in the existing verified plugin registry.

## Acceptance Criteria

- [ ] Add registry entries only for params with canonical id, source, unit, range, tolerance, write/read-back methods, and live evidence.
- [ ] Unknown Channel EQ params continue to fail closed with `unsupported_param_readback`.
- [ ] `logic_plugins.set_param_verified` returns State A only when read-back is within tolerance.
- [ ] Read-back mismatch rolls back or reports failure according to the existing HC v2 contract.
- [ ] Docs clearly state exactly which Channel EQ params are verified.

## Red Tests

- `channelEQRegistryRejectsUncensusedParam`
- `channelEQRegistryResolvesCanonicalParam`
- `channelEQStateAWithinTolerance`
- `channelEQStateCOnReadbackMismatch`
- `channelEQUnsupportedParamStillFailClosed`

## Implementation Boundary

Likely files:

- `Sources/LogicProMCP/Plugins/StockPluginCatalog.swift`
- `Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift` or a method-specific helper
- `Tests/LogicProMCPTests/PluginSetParamVerifiedTests.swift`
- `Scripts/live-e2e-test.py`

## Manual QA Gate

Live scratch duplicate with one State A write and one unsupported-param State C.
