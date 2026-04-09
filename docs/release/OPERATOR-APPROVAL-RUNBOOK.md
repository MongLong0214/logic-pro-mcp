# Operator Approval Runbook

## Why This Exists

`MIDIKeyCommands` and `Scripter` cannot verify Logic Pro internal setup programmatically. They start as `manual_validation_required` and are excluded from routing until an operator explicitly approves them.

## Approve

```bash
LogicProMCP --approve-channel MIDIKeyCommands --approval-note "Imported preset in Logic Pro"
LogicProMCP --approve-channel Scripter --approval-note "Validated Scripter insertion on target track"
```

## List

```bash
LogicProMCP --list-approvals
```

## Revoke

```bash
LogicProMCP --revoke-channel MIDIKeyCommands
LogicProMCP --revoke-channel Scripter
```

## Required Before Approval

- Key Commands preset imported and exercised in Logic Pro
- Scripter inserted and parameter CCs verified
- `logic_system.health` checked before and after approval

## When To Revoke

- Key Commands preset removed or changed
- Scripter removed from channel strip
- Logic Pro template reset
- Incident response after unexplained command failure
