# Logic Pro E2E Checklist

## Preconditions

- Logic Pro installed and launched once
- Accessibility granted
- Automation granted
- MCU device registered
- Scripter inserted on target track
- Key Commands preset imported

## Approval Flow

After manual validation:

```bash
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
LogicProMCP --list-approvals
```

## Test Cases

1. `logic_transport.play`
2. `logic_transport.stop`
3. `logic_tracks.select`
4. `logic_tracks.set_automation` with `trim`
5. `logic_mixer.set_volume`
6. `logic_mixer.set_pan`
7. `logic_mixer.set_plugin_param`
8. `logic_edit.undo`
9. `logic_project.open` with confirmation
10. `logic_system.health` shows:
   - `MIDIKeyCommands.ready == true`
   - `Scripter.ready == true`

## Evidence

- screenshot or screen recording of Logic Pro setup
- `LogicProMCP --check-permissions`
- `LogicProMCP --list-approvals`
- captured `logic_system.health` payload
