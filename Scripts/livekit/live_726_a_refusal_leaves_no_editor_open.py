#!/usr/bin/env python3
"""#726: a verified-plugin call must leave behind no editor it opened — refusals included.

Why this exists, stated plainly: the defect it pins was found by an outside reviewer, not by
this repository's tests, and the reason is that every assertion about cleanup lived on the same
side as the bug. The unit test for the count-mismatch refusal reached the exact state and never
asked what was left on screen.

Measured 2026-08-31 against the code before the fix:

    hide all plug-in windows      -> AX reports 0 matching editors
    set_param_verified insert 2   -> C duplicate_plugin_editor_count_mismatch
    editors left open             -> 2          (the operation opened them and walked away)

A leftover editor is not cosmetic. The next duplicate-insert write refuses with
`duplicate_plugin_editor_already_open`, which reads as an unrelated failure, and the run after
that inherits the state — the same shape as three other stale-state failures recorded this week.

The editor count is taken by an independent AX probe, never by the product: the product is the
thing under test and cannot witness this about itself.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


# What this harness proves, for `harness_evidence_coverage.py`.
#
# The acquisition and cleanup contract lives in the verified-plugin channel, and the request
# reaches it through the public dispatcher. It does not exercise the catalogue or the walk.
COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift",
    "Sources/LogicProMCP/Dispatchers/PluginsDispatcher.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
driver = None

# The project fixture: a track carrying the SAME plug-in at two inserts, which is the only
# state that reaches the by-construction acquisition path at all.
PROJECT = "/Users/isaac/Music/Logic/lpm-606-warm.logicx"
TRACK = "0"
DUPLICATED_PLUGIN = "Compressor"
FIRST_INSERT = "0"
SECOND_INSERT = "2"
TRACK_LABEL = "Absolute Zero"
# Localized labels the repository already owns; not new literals.
OPEN_LABEL = "열기"
MIXER_LABELS = ["Mixer", "믹서", "ミキサー"]


def finish(code=1):
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(code)


def compile_probe():
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_plugin_menu_probe.swift")
    tool = os.path.join(ev.dir, "ax_plugin_menu_probe")
    result = subprocess.run(["swiftc", "-O", source, "-o", tool], capture_output=True)
    return tool, result


def open_one_editor(tool, ordinal):
    """Open ONE of the duplicated plug-in's editors, by AX child order in the strip.

    The product now closes the editors it opens, so the harness cannot build a
    pre-existing-editor state through the product. It has to open one itself, and
    it has to name WHICH of the two, since both carry the same name.
    """
    config = {
        "slot_label": DUPLICATED_PLUGIN,
        "open_label": OPEN_LABEL,
        "track_label": TRACK_LABEL,
        "mixer_label": MIXER_LABELS,
        "slot_ordinal": ordinal,
    }
    result = subprocess.run([tool, "open-plugin-editor", json.dumps(config, ensure_ascii=False)],
                            capture_output=True, text=True)
    try:
        return json.loads(result.stdout or "{}")
    except ValueError:
        return {"_raw": (result.stdout or result.stderr)[:400]}


def editors(tool):
    """Every open plug-in editor, read by AX rather than by the product."""
    result = subprocess.run([tool, "plugin-editors", "{}"], capture_output=True, text=True)
    try:
        body = json.loads(result.stdout or "{}")
    except ValueError:
        body = {"_raw": (result.stdout or result.stderr)[:400]}
    body["_returncode"] = result.returncode
    return body


def write_call(insert, value):
    return driver.tool("logic_plugins", "set_param_verified", {
        "track": TRACK,
        "insert": insert,
        "plugin": DUPLICATED_PLUGIN,
        "param": "threshold",
        "value": str(value),
        "unit": "normalized",
        "mode": "duplicate_applyback",
        "project_expected_path": PROJECT,
    }) or {}


probe_tool, build = compile_probe()
ev.check("726/precondition-the-independent-editor-reader-builds",
         build.returncode == 0,
         "the AX probe that counts editors compiles",
         f"swiftc returncode {build.returncode}: {build.stderr.decode()[:200]}",
         "break the probe source and this precondition fails before any verdict is recorded")
if build.returncode != 0:
    finish()

# --- Evidence requires the run to have LOOKED, driven, and recorded. These are not
# --- decoration: a harness that asserts only through its own probe cannot show that
# --- the screen matched what the probe said.
arrange_window = E.logic_window()
ev.check("726/precondition-an-arrange-window-is-visible-for-the-recording",
         isinstance(arrange_window, dict) and bool(arrange_window.get("title")),
         "a visible Logic arrange window supplies the recorded visual control",
         json.dumps(arrange_window, ensure_ascii=False)[:200],
         "close the arrange window: the recording has no defined subject and this turns red")
if not (isinstance(arrange_window, dict) and arrange_window.get("title")):
    finish()

band, band_subject = ev.located_band("Control Bar", "--min-width", "1000")
ev.check("726/precondition-the-visual-band-is-named-by-the-ui",
         band is not None and isinstance(band_subject, str) and bool(band_subject.strip()),
         "an unambiguous region the UI itself names, so the visual assertion has a subject",
         json.dumps({"band": band, "subject": band_subject}, ensure_ascii=False)[:200],
         "make the Control Bar lookup ambiguous: no anonymous rectangle is substituted")
if band is None or not (isinstance(band_subject, str) and band_subject.strip()):
    finish()

recording = ev.record_screen(seconds=90)

driver = E.Driver()
driver.tool("logic_system", "refresh_cache", {})

# --- Baseline: nothing open before the run, or nothing later means anything. ---
start = editors(probe_tool)
ev.check("726/precondition-no-plugin-editor-is-open-before-the-run",
         start.get("editor_count") == 0,
         "zero plug-in editors before the first call",
         json.dumps(start, ensure_ascii=False)[:300],
         "leave an editor open before the run and every later count is inherited, not caused")
if start.get("editor_count") != 0:
    finish()

# --- 1. A SUCCESSFUL duplicate write closes the editor it opened. ---
ok = write_call(FIRST_INSERT, 56)
after_success = editors(probe_tool)
ev.falsifiable(
    "726/a-successful-duplicate-write-leaves-no-editor-open",
    lambda obs: obs.get("state") == "A" and obs.get("editors", {}).get("editor_count") == 0,
    {"state": ok.get("state"), "error": ok.get("error"), "editors": after_success},
    {"state": "A", "error": None, "editors": {"editor_count": 1, "editors": [{"title": TRACK}]}},
    "State A and zero editors left open",
    mutation="remove the cleanup defer and this observes State A with one editor still open",
)

# --- 2. A REFUSAL closes it too. This is the half that was missing. ---
#
# The count-mismatch refusal is reached by hiding the editors first: AX then reports zero, one
# press restores BOTH, the post-count is two, and the call correctly refuses. What it must also
# do is put back what it disturbed.
opened = open_one_editor(probe_tool, 0)
present = editors(probe_tool)
ev.check("726/precondition-one-sibling-editor-is-actually-open-before-hiding",
         opened.get("editor_count") is None and present.get("editor_count") == 1,
         "exactly one editor is open before the hide, so the hide has something to hide",
         json.dumps({"open": opened.get("outcome"), "editors": present}, ensure_ascii=False)[:300],
         "an earlier version skipped this and read 0 == 0 after hiding nothing, which passed "
         "vacuously and let the refusal case never be reached")
if present.get("editor_count") != 1:
    driver.close()
    finish()

# Logic REWRITES this item's title with its own state — it reads
# «모든 플러그인 윈도우 가리기» (hide) when windows are showing and
# «모든 플러그인 윈도우 보기» (show) when they are hidden. A fixed string
# matches in one state and raises -1728 in the other, and the harness then
# hid nothing while believing it had. Resolve by the stable stem instead.
subprocess.run(["osascript", "-e",
                'tell application "System Events" to tell process "Logic Pro"\n'
                '  set m to first menu item of menu 1 of menu bar item "윈도우" of menu bar 1 '
                'whose name contains "모든 플러그인 윈도우"\n'
                '  click m\n'
                'end tell'],
               capture_output=True)
time.sleep(1.5)
hidden = editors(probe_tool)
ev.check("726/precondition-hiding-makes-the-open-editor-invisible-to-ax",
         hidden.get("editor_count") == 0,
         "AX reports zero editors although one IS open, which is what makes a zero pre-count "
         "insufficient on its own",
         json.dumps(hidden, ensure_ascii=False)[:300],
         "if hiding did not empty the AX list this precondition fails and the case below is "
         "not the one it claims to be")
if hidden.get("editor_count") != 0:
    driver.close()
    finish()

refused = write_call(SECOND_INSERT, 70)
after_refusal = editors(probe_tool)
ev.falsifiable(
    "726/a-refused-duplicate-write-leaves-no-editor-open",
    lambda obs: (obs.get("write_attempted") is False
                 and obs.get("editors", {}).get("editor_count") == 0),
    {"state": refused.get("state"),
     "error": refused.get("error"),
     "write_attempted": refused.get("write_attempted"),
     "editors": after_refusal},
    {"state": "C", "error": "duplicate_plugin_editor_count_mismatch", "write_attempted": False,
     "editors": {"editor_count": 2, "editors": [{"title": "x"}, {"title": "x"}]}},
    "the refusal attempted no write AND left no editor open",
    mutation="register the cleanup after the count-mismatch return and this observes two "
            "editors still open, which is exactly what was measured before the fix",
)

# --- 3. The project is where it started. A cleanup check must not itself drift the session. ---
final = write_call(FIRST_INSERT, 56)
ev.check("726/the-run-restored-the-parameter-it-moved",
         final.get("state") == "A" and final.get("observed_normalized") == 56,
         "the duplicated plug-in is back at 56 and the restore was read back, not assumed",
         json.dumps({"state": final.get("state"),
                     "observed": final.get("observed_normalized")}, ensure_ascii=False),
         "skip the restore and this observes a different value than the one the run started from")

before_shot = ev.shot("726/before-comparison", settle_region=band,
                      window_title=arrange_window["title"])

end = editors(probe_tool)
ev.check("726/the-run-left-no-editor-open",
         end.get("editor_count") == 0,
         "zero plug-in editors when the harness ends",
         json.dumps(end, ensure_ascii=False)[:300],
         "leave one open and the next run inherits it, which is how three stale-state failures "
         "started this week")

driver.close()

# The Control Bar is the visual control, not the witness for cleanup: the editors
# this harness opens and closes are separate windows and never overlap this band.
# What it establishes is that the run did not disturb the arrangement while doing
# all of the above — a cleanup check that silently moved the transport would be a
# worse instrument than none.
after_shot = ev.shot("726/after-comparison", settle_region=band,
                     window_title=arrange_window["title"])
ev.visual(
    "726/opening-and-closing-plugin-editors-does-not-disturb-the-arrangement",
    before_shot["file"], after_shot["file"], band, expect_change=False, subject=band_subject,
    why="the harness opened, hid and closed plug-in editors and wrote one parameter twice; the "
        "Control Bar is not part of any of that and must be byte-identical across it",
)
ev.stop_recording(recording)

out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
