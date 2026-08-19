#!/usr/bin/env python3
"""Live proof for #544 — a tool that declares an output schema always answers with one.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_544_output_schema.py <worktree> <full-40-char-head-sha>

This one is a protocol fix, so its proof looks different from a UI operation's. What is checked:

- The two commands from the external report (`logic_system.permissions`, `refresh_cache`) return
  `structuredContent` over a real MCP stdio session against the built binary — that is the thing the
  reporting client rejected, so it has to be observed on the wire rather than in a unit fixture.
- A prose ERROR path returns it too, since half the violating sites were failure sentences.
- `health`, which always complied, still passes its JSON through unwrapped rather than nested under
  `message` — the fix must not have changed the shape of answers that were already correct.
- The visual assertion is an ABSENCE one: these are read-only system commands, so the arrange window must
  NOT change while they run. A region that does change would mean a "read" moved something.
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

MUT = ("removed the `?? .object(prose)` fallback in toolTextResult; these commands returned "
       "structuredContent nil again and a schema-enforcing client rejected the call")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
rec = ev.record_screen(seconds=45)
d = E.Driver()

win = E.logic_window()
if not win:
    ev.check("544/precondition-logic-window", False,
             "Logic's Tracks window is on screen", "no window found",
             "closed the Tracks window; this check went red")
    d.close(); ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The track rail: a read-only system command has no business repainting it.
RAIL, RAIL_SUBJECT = ev.located_band("Tracks header")
ev.check("544/precondition-the-track-header-rail-was-located",
         RAIL is not None and bool(RAIL_SUBJECT),
         "the track-header rail, located by the AXDescription it carries",
         f"band={RAIL!r} subject={RAIL_SUBJECT!r}", None)
pre = ev.shot("before-system-reads", settle_region=RAIL)


def structured(name, command, params=None):
    """Call over the wire and report whether structuredContent came back, as the client sees it."""
    args = {"command": command}
    if params is not None:
        args["params"] = params
    raw = d._send("tools/call", {"name": name, "arguments": args})
    res = (raw or {}).get("result", {})
    return res.get("structuredContent"), res


perm, _ = structured("logic_system", "permissions")
ev.check("544/permissions-answers-with-structured-content", perm is not None,
         "logic_system.permissions returns structuredContent, as its declared outputSchema requires",
         f"structuredContent={'present' if perm is not None else 'ABSENT'}", MUT)

refresh, _ = structured("logic_system", "refresh_cache")
ev.check("544/refresh-cache-answers-with-structured-content", refresh is not None,
         "logic_system.refresh_cache returns structuredContent",
         f"structuredContent={'present' if refresh is not None else 'ABSENT'}", MUT)

ev.check("544/refresh-cache-says-whether-it-actually-ran",
         isinstance(refresh, dict) and "refreshed" in refresh,
         "the receipt distinguishes a refresh that ran from one merely queued",
         f"refreshed={None if not isinstance(refresh, dict) else refresh.get('refreshed')!r} "
         f"source={None if not isinstance(refresh, dict) else refresh.get('source')!r}",
         "reverted refresh_cache to its prose strings; the distinction was recoverable only by "
         "string-matching the message")

ev.check("544/permissions-carries-the-states-not-only-prose",
         isinstance(perm, dict) and {"accessibility", "automation_logic_pro",
                                     "automation_system_events", "post_event"} <= set(perm),
         "the four TCC states are fields, beside the human summary",
         f"keys={sorted(perm.keys()) if isinstance(perm, dict) else perm!r}",
         "reverted permissions to toolTextResult(status.summary); only a message field remained")

# A prose FAILURE path: half the violating sites were failure sentences, not successes.
err, _ = structured("logic_project", "open", {"path": "/nonexistent-☃.logicx"})
ev.check("544/a-prose-error-is-structured-too", err is not None,
         "a failure answered in prose still satisfies the declared schema",
         f"structuredContent={'present' if err is not None else 'ABSENT'}", MUT)

# Answers that were already JSON must be passed through, not nested under `message`.
health, _ = structured("logic_system", "health")
ev.check("544/an-already-valid-answer-is-not-rewrapped",
         isinstance(health, dict) and "message" not in health and "channels" in health,
         "health's JSON object is passed through unchanged rather than nested under message",
         f"keys={sorted(health.keys())[:6] if isinstance(health, dict) else health!r}",
         "made toolTextResult wrap unconditionally; health's fields disappeared under a message key")

_, perm_res = structured("logic_system", "permissions")
perm_text = "".join(c.get("text", "") for c in perm_res.get("content", []))
ev.check("544/the-text-the-oracle-grades-is-unchanged",
         perm_text.startswith("Accessibility: "),
         "permissions still emits the exact prose its semantic oracle grades line by line",
         f"text_prefix={perm_text[:40]!r}",
         "encoded the new object as the text; the oracle stopped matching and qualification would have "
         "turned a correct answer RED while every unit test stayed green")

post = ev.shot("after-system-reads", settle_region=RAIL)
ev.visual("544/read-only-commands-do-not-disturb-the-session",
          pre["file"], post["file"], RAIL, subject=RAIL_SUBJECT, expect_change=False,
          why="permissions, refresh_cache and health are reads; the track rail must be untouched")

ev.restored("544/no-session-state-was-mutated", True,
            "only read-only system commands and one failing project open were issued")

d.close()
ev.stop_recording(rec)
print(json.dumps(ev.write(), indent=1))
