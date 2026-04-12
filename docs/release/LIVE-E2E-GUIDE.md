# Live E2E Testing Guide

The live E2E test suite (`scripts/live-e2e-test.py`) drives the built MCP binary against a running Logic Pro instance via JSON-RPC over stdio. It is **not** run in CI because CI runners do not have Logic Pro installed.

---

## When to run

- Before merging any PR touching channels, state, routing, or security
- Before cutting a release
- Whenever the `health`/resource JSON schema changes
- When validating a fresh machine install

---

## Prerequisites

1. macOS 14+
2. **Logic Pro 12.0+ running** (an empty project is fine; some tests are more meaningful with tracks loaded)
3. Accessibility + Automation permissions granted to your terminal (or Claude Code)
4. Release (or debug) binary built: `swift build -c release` (or `swift build`)
5. MCU control surface registered in Logic Pro — see [MCU-SETUP.md](../MCU-SETUP.md). Without MCU, the mixer write tests will surface `All channels exhausted` errors (which the test suite treats as a known skip condition).

---

## Running

```bash
# From the repo root
python3 scripts/live-e2e-test.py
```

The script spawns a fresh `LogicProMCP` subprocess, performs the MCP handshake, then runs 229 tests across 20 sections. Output is line-colored; exit code is the failure count (0 on success).

Expected runtime: ~60 seconds on a warm cache.

---

## Sections

| § | Section | # Tests | Notes |
|---|---------|---------|-------|
| 0 | MCP Handshake | 1 | `initialize` + `notifications/initialized` |
| 1 | Protocol Contract | 12 | tools/list (8), resources/list (6), templates/list (1) |
| 2 | System Diagnostics | 20 | `help`, `health` schema, `permissions`, `refresh_cache` |
| 3 | Transport Live | 17 | get_state via resource, cycle/metronome toggle roundtrip, tempo/position |
| 4 | Track Live | 20 | get_tracks via resource, select/mute/solo/arm |
| 5 | Mixer Live | 18 | volume/pan ranges, channel_strip reads |
| 6 | MIDI Live | 25 | note/chord ranges, CC, PC, PB, AT, MMC, step_input |
| 7 | Edit Commands | 14 | all 14 edit commands |
| 8 | Navigation | 13 | markers, zoom directions, 7 view toggles |
| 9 | Project | 5 | get_info, is_running, save/bounce/launch |
| 10 | Security: Path Validation | 15 | 15 attack vectors all rejected |
| 11 | Resource Read | 18 | 6 resources × schema checks |
| 12 | Error Handling | 16 | unknown commands, missing params |
| 13 | Concurrent Stress | 5 | 30 sequential, 20 rapid notes, 20 reads, interleaved |
| 14 | State Consistency | 7 | tool vs resource agreement, uptime monotonic |
| 15 | Input Validation | 12 | non-numeric, extreme values, unicode |
| 16 | Routing & Fallback | 5 | MCU-only vs chain-routed ops |
| 17 | Real MIDI Flow | 6 | virtual ports visible in system MIDI |
| 18 | Performance | 5 | latency thresholds for each op class |
| 19 | Memory & Stability | 3 | 50-call memory delta |
| 20 | Final Verification | 2 | permissions + channels at end of run |

---

## Interpreting results

### All pass (green)

```
══════════════════════════════════════════════════════
 ✔ All 229 tests passed
══════════════════════════════════════════════════════
```

Ship it.

### MCU-dependent failures

If MCU is not registered, you may see:

```
✘ mixer.set_volume dispatches (MCU-only channel)
  response: All channels exhausted for mixer.set_volume. Last error: Channel MCU: MCU feedback not detected. ...
```

This is **expected behavior** when MCU is not registered. Follow [MCU-SETUP.md](../MCU-SETUP.md) to register, then re-run.

### Permission failures

```
✘ system.permissions shows granted
```

Indicates macOS Accessibility or Automation is not granted to the process. Run `LogicProMCP --check-permissions` and follow the prompts in System Settings.

### Timing / flaky failures

The concurrent-stress section fires many requests in rapid succession. Transient timeouts (`no response`) occasionally occur on cold machines. Re-run once to confirm before filing a bug.

---

## CI integration

Live E2E is **not automated in CI** because:

1. GitHub Actions macOS runners do not have Logic Pro installed.
2. Logic Pro license prohibits redistribution / automated provisioning.
3. MCU handshake requires user-initiated setup.

Instead, this suite runs:

- On the maintainer's machine before each release tag
- On a clean-machine validator follow-up run (see `CLEAN-MACHINE-VALIDATION.md`)
- Output captured in `RELEASE-EVIDENCE-YYYY-MM-DD.md`

### Self-hosted runner option

Teams with dedicated macOS hardware can set up a self-hosted GitHub runner with Logic Pro pre-installed:

```yaml
# .github/workflows/live-e2e.yml (example — NOT enabled by default)
jobs:
  live-e2e:
    runs-on: [self-hosted, macos, logic-pro]
    steps:
      - uses: actions/checkout@v4
      - run: swift build -c release
      - run: python3 scripts/live-e2e-test.py
```

This requires:
- The runner host is logged into a user account with Logic Pro
- Logic Pro is launched and a project is open
- Accessibility + Automation permissions are granted to the runner agent
- MCU control surface is pre-registered

---

## Extending the suite

Add new tests inside the appropriate `banner(...)` section. Pattern:

```python
step(N, "Description")
r = call_tool(client, "logic_xxx", "command", {"param": value})
T("what you're asserting", r, lambda _: <predicate on response>)
```

For resource reads:

```python
step(N, "Description")
text = resource_text(read_resource(client, "logic://..."))
json_obj = safe_json(text)
T("resource X has field Y", "ok", lambda _: json_obj.get("Y") is not None)
```

Update the section count in this doc when you add a section.
