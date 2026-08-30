#!/usr/bin/env python3
"""Live proof that every stock Channel EQ band is individually addressable over AX.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_301_channel_eq_bands_are_addressable.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
The Channel EQ accessibility walk knew that an insert slot could be named, but nobody had measured
whether opening that slot led to every band control rather than to an unlabelled visual editor. The
throwaway probe made this worse on its first pass: it pressed every pressable slot child, including
the bypass checkbox, then had to undo the change. A harness that cannot notice that side effect is
not evidence that the opening path is safe.

WHAT IS MEASURED NOW, AND WHAT IS STILL NOT
-------------------------------------------
On Korean Logic 12.x, the `Channel EQ` AXGroup has an AXButton `열기` and an AXCheckBox `바이패스`.
Opening it through that button exposes an AXGroup `EQ` containing eight named band enables and 24
named sliders. Each measured slider declares that its AXValue is settable and gives an engineering
unit AXValueDescription.

NO WRITE IS ATTEMPTED. `settable` is a claim by the element, and AX settability has lied in this
codebase's experience. This proves addressability and readability, not that a write would land.
"""

from collections import Counter
import json
import os
import subprocess
import sys

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

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])

# These labels were read on Korean Logic 12.x only. There is deliberately no translated fallback:
# a run on another Logic locale yields an absent element instead of pressing or naming the wrong one.
SLOT = "Channel EQ"
OPEN = "열기"
CLOSE = "닫기"
EQ_GROUP = "EQ"
BANDS = ["Low Cut", "Low Shelf", "Peak 1", "Peak 2", "Peak 3", "Peak 4", "High Shelf", "High Cut"]

# The 24 band parameters by name. Low Cut and High Cut take an Order where the others take a Gain,
# which is why this is a list and not a product of BANDS and three suffixes.
BAND_PARAMETERS = [
    "Low Cut Frequency", "Low Cut Order", "Low Cut Q",
    "Low Shelf Frequency", "Low Shelf Gain", "Low Shelf Q",
    "Peak 1 Frequency", "Peak 1 Gain", "Peak 1 Q",
    "Peak 2 Frequency", "Peak 2 Gain", "Peak 2 Q",
    "Peak 3 Frequency", "Peak 3 Gain", "Peak 3 Q",
    "Peak 4 Frequency", "Peak 4 Gain", "Peak 4 Q",
    "High Shelf Frequency", "High Shelf Gain", "High Shelf Q",
    "High Cut Frequency", "High Cut Order", "High Cut Q",
]

# Measured 2026-08-30: the EQ group exposes 26 sliders, not 24. The 24 above plus TWO output `Gain`
# sliders sharing one description. An earlier draft of this harness asserted `len(sliders) == 24`
# because that is the number I wrote in the issue comment, counting band parameters and calling it
# the group total. Every slider assertion below failed on a reading that was RIGHT. Assert the names
# that must be present and the property that must hold of every slider; do not assert a total that
# was arrived at by arithmetic rather than by counting what came back.

# `pluginOpenOrListControl` is intentionally a combined LabelSet (`open` AND `list`). It is useful
# for documenting the slot's known controls, but unsafe as an action selector because `목록` is also
# an AXButton. The one safe action label observed here is the Korean `열기` above.
OPEN_OR_LIST_LABELS = E.label_set("pluginOpenOrListControl")
BYPASS_LABELS = E.label_set("pluginBypassControl")


def finish(code=1):
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(code)


def compile_probe():
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_plugin_menu_probe.swift")
    tool = os.path.join(ev.dir, "ax_plugin_menu_probe")
    result = subprocess.run(["swiftc", "-O", source, "-o", tool], capture_output=True)
    return tool, result


def probe(tool, mode, config):
    result = subprocess.run([tool, mode, json.dumps(config, ensure_ascii=False)],
                            capture_output=True, text=True)
    try:
        body = json.loads(result.stdout or "{}")
    except ValueError:
        body = {"_raw": (result.stdout or result.stderr)[:400]}
    body["_returncode"] = result.returncode
    return body


def clean_texts(nodes, key="description"):
    return [node.get(key, "") for node in nodes if isinstance(node, dict)]


# `Evidence.check` records modal state per check, but that only marks contaminated observations red
# after they were made. Refuse before compiling, reading, or pressing: a hardware dialog would make
# every later AX value a reading through the modal, which is precisely what this branch forbids.
modal = E.blocking_modal()
ev.check("301/precondition-no-blocking-modal",
         modal is None,
         "no CoreGraphics modal-panel window belongs to Logic before this run reads an insert slot",
         f"blocking_modal={modal!r}",
         "put up Logic's audio-hardware alert: this precondition goes red and the run stops before "
         "recording any Channel EQ value")
if modal is not None:
    finish()

policy_ready = (isinstance(OPEN_OR_LIST_LABELS, list) and OPEN in OPEN_OR_LIST_LABELS
                and isinstance(BYPASS_LABELS, list) and bool(BYPASS_LABELS))
ev.check("301/precondition-the-measured-control-labels-are-in-the-locale-policy",
         policy_ready,
         "the policy still declares the measured open/list and bypass control label families",
         f"open_or_list={OPEN_OR_LIST_LABELS!r} bypass={BYPASS_LABELS!r}",
         "remove `열기` or the bypass labels from the policy: the harness refuses rather than using "
         "a stale selector")
if not policy_ready:
    finish()

tool, built = compile_probe()
ev.check("301/precondition-the-raw-ax-witness-built",
         built.returncode == 0,
         "the independent raw-AX witness compiled; System Events would synthesise descriptions and "
         "cannot establish the slider attributes below",
         f"rc={built.returncode} stderr={(built.stderr or b'').decode('utf-8', 'replace')[:300]!r}",
         "break the witness source: no raw-attribute reading is available and this goes red")
if built.returncode != 0:
    finish()

arrange = E.logic_window()
band = (0, 0, arrange["w"], 28) if arrange else None
band_subject = f"the title bar of the {arrange['title']!r} document window" if arrange else None
ev.check("301/precondition-a-project-window-is-open",
         arrange is not None and band is not None and bool(band_subject),
         "a Logic arrange window is on screen, so the insert slot and the unchanged-document capture "
         "have a project to refer to",
         f"arrange={arrange!r} band={band!r}",
         "close the project: there is no project insert slot or document window and this goes red")
if band is None:
    finish()

slot_before = probe(tool, "plugin-slot", {"slot_label": SLOT})
ev.note("301/channel-eq-slot-before-opening", slot_before)
ev.falsifiable(
    "301/precondition-one-channel-eq-insert-slot-resolves-by-description",
    lambda observed: observed.get("slot_count") == 1,
    slot_before,
    {"slot_count": 0},
    "exactly one AXGroup describes itself `Channel EQ`, so the run will not choose a slot by tree "
    "order or coordinates",
    "rename or remove the Channel EQ insert: its count becomes zero and the precondition goes red",
)
if slot_before.get("slot_count") != 1:
    finish()

slot_children = slot_before.get("slot_children") if isinstance(slot_before.get("slot_children"), list) else []
slot_shape = (
    any(isinstance(child, dict) and child.get("role") == "AXButton"
        and child.get("description") == OPEN for child in slot_children)
    and any(isinstance(child, dict) and child.get("role") == "AXButton"
            and child.get("description") == "목록" for child in slot_children)
    and any(isinstance(child, dict) and child.get("role") == "AXCheckBox"
            and child.get("description") in BYPASS_LABELS for child in slot_children)
)
ev.falsifiable(
    "301/the-channel-eq-slot-has-the-measured-open-list-and-bypass-children",
    lambda observation: observation["ok"],
    {"ok": slot_shape},
    {"ok": False},
    "the named Channel EQ AXGroup contains AXButtons `열기` and `목록`, plus a named bypass AXCheckBox",
    "change a child role or label: the slot signature goes red before the harness attempts its Open press",
)
if not slot_shape:
    finish()

rec = ev.record_screen(seconds=90)
before = ev.shot("301/before", settle_region=band, window_title=arrange["title"])

# A wire read marks the release artifact under test as having served this run. It changes no Logic
# state; the actual Channel EQ observation is the independent raw-AX witness below.
driver = E.Driver()
health = driver.tool("logic_system", "health", {})
ev.falsifiable("301/the-release-artifact-answers-a-read-only-wire-request",
               lambda body: isinstance(body, dict) and bool(body), health, {},
               "the built server answered a read-only health request during this evidence run",
               "start an artifact that cannot answer MCP: the empty/error response goes red")

result = probe(tool, "channel-eq", {
    "slot_label": SLOT,
    "open_label": OPEN,
    "close_label": CLOSE,
    "bypass_labels": BYPASS_LABELS,
})
ev.note("301/channel-eq-raw-ax", result)

opening = result.get("open") if isinstance(result.get("open"), dict) else {}
pressed = opening.get("pressed_children") if isinstance(opening.get("pressed_children"), list) else []
open_buttons = (opening.get("open_button_candidates")
                if isinstance(opening.get("open_button_candidates"), list) else [])
opened_windows = opening.get("opened_windows") if isinstance(opening.get("opened_windows"), list) else []
opened_only_by_open_button = (
    opening.get("slot_count") == 1
    and len(open_buttons) == 1
    and len(pressed) == 1
    and pressed[0].get("role") == "AXButton"
    and pressed[0].get("description") == OPEN
    and len(opened_windows) == 1
)
ev.falsifiable(
    "301/the-plugin-window-opened-through-only-the-open-button",
    lambda observation: observation["opened"],
    {"opened": opened_only_by_open_button},
    {"opened": False},
    "one new plug-in window appeared after exactly one press, and that press was AXButton `열기`; "
    "no other pressable slot child was pressed",
    "include every pressable child again: the bypass checkbox enters `pressed_children` and this "
    "check goes red even if a window still opens",
)

checkboxes = result.get("band_checkboxes") if isinstance(result.get("band_checkboxes"), list) else []
band_names = clean_texts(checkboxes)
bands_resolve = (result.get("eq_group_count") == 1
                 and all(band in band_names for band in BANDS))
ev.falsifiable(
    "301/each-of-the-eight-band-enables-resolves-by-name",
    lambda observation: observation["ok"],
    {"ok": bands_resolve},
    {"ok": False},
    "the EQ group exposes an AXCheckBox for each of the eight measured band names; it carries "
    "others too (Analyzer, Q-Couple, HQ), so this is containment and not equality",
    "remove or rename a band label: the containment assertion goes red",
)

sliders = result.get("sliders") if isinstance(result.get("sliders"), list) else []
slider_descriptions = [
    slider.get("description", "") for slider in sliders if isinstance(slider, dict)
]
all_slider_descriptions = all(p in slider_descriptions for p in BAND_PARAMETERS) and all(
    isinstance(slider, dict) and isinstance(slider.get("description"), str)
    and slider["description"].strip()
    for slider in sliders
)
ev.falsifiable(
    "301/every-band-parameter-resolves-by-name-and-every-slider-is-named",
    lambda observation: observation["ok"],
    {"ok": all_slider_descriptions},
    {"ok": False},
    "all 24 band parameters resolve by name, and every slider in the EQ group carries its own "
    "non-empty raw AXDescription",
    "strip one description, or rename a band parameter: the name assertion goes red",
)

all_settable = all(p in slider_descriptions for p in BAND_PARAMETERS) and all(
    isinstance(slider, dict) and slider.get("value_settable") is True for slider in sliders
)
ev.falsifiable(
    "301/every-slider-in-the-eq-group-claims-its-value-is-settable",
    lambda observation: observation["ok"],
    {"ok": all_settable},
    {"ok": False},
    "all 24 band parameters are present and every slider in the EQ group reports AXValue "
    "settable=true",
    "make any slider report settable=false: the universal assertion goes red",
)

all_value_descriptions = all(p in slider_descriptions for p in BAND_PARAMETERS) and all(
    isinstance(slider, dict) and isinstance(slider.get("value_description"), str)
    and slider["value_description"].strip()
    for slider in sliders
)
ev.falsifiable(
    "301/every-slider-in-the-eq-group-has-an-engineering-value-description",
    lambda observation: observation["ok"],
    {"ok": all_value_descriptions},
    {"ok": False},
    "all 24 band parameters are present and every slider in the EQ group carries a non-empty "
    "AXValueDescription such as Hz, dB, or Q",
    "clear one value description: this goes red while the description and settability checks can "
    "still pass",
)

bypass_candidates = result.get("bypass_candidates") if isinstance(result.get("bypass_candidates"), list) else []
bypass_before = result.get("bypass_before")
bypass_after = result.get("bypass_after")
bypass_unchanged = (len(bypass_candidates) == 1 and bypass_before is not None
                    and bypass_after is not None and bypass_after == bypass_before)
ev.falsifiable(
    "301/negative-control-the-bypass-checkbox-value-is-unchanged",
    lambda observation: observation["ok"],
    {"ok": bypass_unchanged},
    {"ok": False},
    "the named bypass checkbox has the same AXValue before the Open press and after the plug-in "
    "window closes",
    "press the bypass checkbox as the old probe did: its before/after values differ and this goes red",
)

close = result.get("close") if isinstance(result.get("close"), dict) else {}
closed = (close.get("pressed") is True and close.get("window_still_present") is False)
ev.check("301/the-plugin-window-opened-by-this-run-is-closed-again",
         closed,
         "the exact plug-in window the Open button created was closed through its named close button",
         f"close={close!r}",
         "make the close button absent or leave the window open: this restoration check goes red")
ev.restored("301/the-channel-eq-window-is-back-where-it-started", closed,
            f"close={close!r}; the only UI state this harness changes is the plug-in window it opened")

after = ev.shot("301/after", settle_region=band, window_title=arrange["title"])
ev.visual("301/opening-and-closing-channel-eq-does-not-change-the-project",
          before["file"], after["file"], band, subject=band_subject, expect_change=False,
          why="the harness opened and closed a pre-existing insert window only; it attempted no EQ or "
              "project write, so the document title band must be unchanged")

driver.close()
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
