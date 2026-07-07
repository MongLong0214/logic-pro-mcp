# T3: Relative / PATH-Dependent Registration Resolver

**Priority**: P1
**Status**: Todo
**Depends On**: T2

## Objective

Replace the v3 "relative command is skipped" behavior with a three-state `RegisteredCommandResolution`: `absolute`, `path_resolved`, `unresolved_path_dependent`.

## Acceptance Criteria

- [ ] Absolute registered command remains direct.
- [ ] Bare command like `LogicProMCP` attempts PATH resolution using the same launch-context environment model.
- [ ] Resolved command is checked for regular file, executable bit, and static version.
- [ ] Unresolved path-dependent command is skipped with `skip_reason:path_dependent_unresolved`.
- [ ] No `$PATH` full walk beyond bounded resolver.

## Red Tests

- `registeredCommandAbsoluteResolves`
- `registeredCommandBarePathResolved`
- `registeredCommandBareUnresolvedGetsSkipReason`
- `registeredCommandDirectoryIsWarnNotVersionChecked`
- `registeredCommandResolutionDoesNotExecuteTargetBinary`

## Implementation Boundary

Likely files: `SetupDoctor+MCPChecks.swift`, `SetupDoctor+ProductionSupport.swift`, `DoctorTool.swift`, tests around registration config.

## QA Gate

Fixture tests for Claude Code, Claude Desktop, and custom MCP configs.
