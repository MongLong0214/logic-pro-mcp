# Summary

## What changed
- 

## Linked issue
Closes #

## Why this is safe
- Target validation:
- Readback/provenance:
- Destructive or irreversible behavior:
- Compatibility impact:

# Verification

## Deterministic checks
- [ ] `swift build`
- [ ] `swift test`
- [ ] `swift build -c release`
- [ ] Targeted test command:

## Logic Pro live evidence
- [ ] Not required; change is docs/tests/tooling-only.
- [ ] Required and attached below.

Live evidence:
```text

```

## Honest Contract impact
- [ ] No mutating operation contract changed.
- [ ] State A/B/C behavior changed and tests/docs were updated.
- [ ] New or changed failure reasons are documented.

Details:
```text

```

# Release and docs
- [ ] README updated if public claims changed.
- [ ] `docs/API.md` updated if MCP surface changed.
- [ ] `docs/TROUBLESHOOTING.md` updated for new user-facing failure modes.
- [ ] `CHANGELOG.md` updated under `[Unreleased]` when behavior changed.
- [ ] Release/install metadata unaffected, or all versioned release surfaces were updated together.

# Reviewer focus
- Risk level: P0 / P1 / P2 / P3
- Areas to inspect first:
- Known limitations:
