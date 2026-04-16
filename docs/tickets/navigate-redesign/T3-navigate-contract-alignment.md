# T3: Align navigate contract after T1+T2

**Priority**: P2
**Size**: S
**Status**: Blocked by T1 and T2

## Objective

Once `goto_bar` has a real channel (T1) and markers are actually cached
(T2), close the loop so the public docs and the dispatcher description
match reality again.

## Acceptance Criteria

- [ ] `docs/API.md` `logic_navigate` section: remove the "Known gaps" callout, update the channel column for `goto_bar`.
- [ ] `README.md` `logic_navigate` details block: remove the ⚠️ warning, add usage examples for `goto_bar` and `goto_marker { name: ... }`.
- [ ] `NavigateDispatcher` tool description reflects final param shapes.
- [ ] Live e2e test in `Scripts/live-e2e-test.py` covers goto_bar + goto_marker by name.
