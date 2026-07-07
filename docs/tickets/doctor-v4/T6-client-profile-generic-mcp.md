# T6: Client Profile / Generic MCP Client

**Priority**: P1
**Status**: Implemented
**Depends On**: T3

## Objective

Add `ClientProfile` so Claude Code/Desktop checks are required only when that client is selected, while Cursor/VS Code/terminal/custom get relevant launch and registration guidance.

## Acceptance Criteria

- [ ] Profiles: `auto`, `claude-code`, `claude-desktop`, `cursor`, `vscode`, `terminal`, `custom`.
- [ ] Cursor/custom users do not receive required Claude Code registration warnings by default.
- [ ] Claude Code/Desktop profiles keep their registration checks required.
- [ ] Launch context classification expands to Cursor, VS Code, Windsurf, Zed, and custom.
- [ ] Human output says which client was evaluated.

## Red Tests

- `cursorProfileDoesNotRequireClaudeCodeRegistration`
- `claudeCodeProfileRequiresClaudeCodeRegistration`
- `claudeDesktopProfileRequiresDesktopRegistration`
- `launchContextClassifiesCursorVSCodeWindsurfZed`
- `customClientRequiresExplicitCommandOrConfig`

## Implementation Boundary

Likely files: `SetupDoctor+LaunchContextSupport.swift`, `SetupDoctor+MCPChecks.swift`, `MainEntrypoint.swift`, docs.

## QA Gate

Fixture matrix for every client profile.

## Implementation Evidence

- `ClientProfile` supports `auto`, `claude-code`, `claude-desktop`, `cursor`, `vscode`, `terminal`, `custom`.
- Explicit `--client terminal` scopes Claude-specific registration checks out with `skip_reason:client_not_selected`.
- Launch-context classification now recognizes Cursor and VS Code and treats Windsurf/Zed as generic custom hosts.
- Focused verification: `testDoctorV4ExplicitCoreProfileScopesManualChannels`.
