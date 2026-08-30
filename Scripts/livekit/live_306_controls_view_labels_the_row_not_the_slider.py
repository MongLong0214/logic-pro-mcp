#!/usr/bin/env python3
"""Live proof that Compressor's Controls view labels a row, not its sliders.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_306_controls_view_labels_the_row_not_the_slider.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
The first conclusion from Compressor's native editor was backwards: because the Controls view shows
parameter names beside its controls, it was assumed those names belonged to the AXSliders. They do
not. Matching `AXSlider` by its own AXDescription therefore reaches Threshold in the native editor,
but not the generic Controls view.

WHAT IS MEASURED NOW, AND WHAT IS STILL NOT
-------------------------------------------
On Korean Logic 12.x, Compressor's native editor exposes 22 sliders on one instance and 20 on
another in the same project - the count follows the instance's configuration. On both, only
`Threshold` has a raw
AXDescription, and 11 sliders claim their values are settable. The `보기` menu offers `컨트롤` and
`편집기`. In Controls view, parameter names live in AXStaticText inside AXCells of AXRows; the
controls beside them can be AXSlider, AXRadioButton, or AXPopUpButton. The measured Controls view
has 26 sliders, and none has an AXDescription of its own.

This harness is bound to the measured project, which contains the Compressor on a channel strip
named `Absolute Zero`. On another project that named strip can be absent or ambiguous, so the
harness refuses rather than measuring a Compressor on the wrong track.

The mixer must already be open. The named strip is resolved only inside the named mixer layout area
whose ancestor chain contains an AXGroup with that same label. The Inspector also displays a
selected track's channel strip as an AXLayoutArea with the mixer label, so name and role alone are
ambiguous. If the mixer is closed, absent, ambiguous, or exceeds the bounded ancestor search, this
harness refuses rather than opening it or choosing between elements by position.

This harness changes only the plug-in view and window. It switches back to the editor, proves that
switch happened from the editor's distinct AX signature, and closes the window. It does not attempt
to write a Compressor parameter.
"""

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
# another locale records an absent element rather than asserting a plausible but unmeasured label.
SLOT = "Compressor"
# This harness depends on this measured track existing. Five Compressor inserts exist across the
# mixer's channel strips, and selecting one by position would measure the wrong plug-in without
# detecting it — so the search is scoped to a named strip and refuses if that strip does not hold
# exactly one.
#
# Measured 2026-08-30, per strip: `Absolute Zero` carries TWO Compressors, `Studio Grand` carries
# one, `Audio 1` none. An earlier draft named `Absolute Zero` and the harness refused with
# slot_count 2, which was the refusal working: two inserts on one strip cannot be told apart by
# name, and choosing between them is the thing this scoping exists to prevent.
TRACK = "Studio Grand"
# `mixerNamedElement` is the existing policy-owned, measured mixer label family. Passing it through
# avoids a second Korean literal: a locale outside that measured family resolves no mixer and refuses
# rather than treating a translation as the mixer label.
MIXER = E.label_set("mixerNamedElement")
OPEN = "열기"
CLOSE = "닫기"
CONTROLS = "컨트롤"
EDITOR = "편집기"
THRESHOLD = "Threshold"
PARAMETERS = [
    "Threshold:", "Ratio:", "Attack:", "Release:", "Make Up:", "Knee:", "Peak/RMS:",
    "Auto Gain:", "Distortion:", "Circuit Type:", "Side Chain Detection:",
]

# This policy LabelSet names the View surface in measured locales. It is passed to the raw witness
# rather than spelling a second, unmaintained candidate array here.
VIEW_LABELS = E.label_set("viewMenuBar")
# As in #301, this is a combined Open-or-List policy. It cannot safely choose between two AXButtons,
# so the action selector remains the only measured Korean Open label above.
OPEN_OR_LIST_LABELS = E.label_set("pluginOpenOrListControl")


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


def slider_descriptions(sliders):
    return [slider.get("description", "") for slider in sliders if isinstance(slider, dict)]


def row_static_texts(rows):
    texts = []
    named_rows = 0
    for row in rows if isinstance(rows, list) else []:
        cells = row.get("cells") if isinstance(row, dict) else []
        row_texts = []
        for cell in cells if isinstance(cells, list) else []:
            values = cell.get("static_texts") if isinstance(cell, dict) else []
            row_texts.extend(value for value in values if isinstance(value, str) and value)
        if row_texts:
            named_rows += 1
            texts.extend(row_texts)
    return texts, named_rows


def all_parameters_are_row_labels(rows):
    texts, named_rows = row_static_texts(rows)
    return named_rows >= len(PARAMETERS) and all(name in texts for name in PARAMETERS)


# Automatic per-check modal receipts only reveal contamination after a check was made. Refuse before
# touching the Accessibility tree or opening Compressor, because a reading through a modal is the
# state this branch exists to prevent from becoming evidence.
modal = E.blocking_modal()
ev.check("306/precondition-no-blocking-modal",
         modal is None,
         "no CoreGraphics modal-panel window belongs to Logic before the Compressor read",
         f"blocking_modal={modal!r}",
         "put up Logic's audio-hardware alert: this goes red and the run stops before a UI read")
if modal is not None:
    finish()

policy_ready = (isinstance(VIEW_LABELS, list) and bool(VIEW_LABELS)
                and isinstance(OPEN_OR_LIST_LABELS, list) and OPEN in OPEN_OR_LIST_LABELS
                and isinstance(MIXER, list) and "믹서" in MIXER)
ev.check("306/precondition-the-view-open-and-mixer-label-policies-are-readable",
         policy_ready,
         "the measured View, Open-or-List, and mixer label families still parse from AXLocalePolicy",
         f"view={VIEW_LABELS!r} open_or_list={OPEN_OR_LIST_LABELS!r} mixer={MIXER!r}",
         "remove a policy LabelSet or the measured `열기`/`믹서` labels: this refuses instead of "
         "selecting from guessed labels")
if not policy_ready:
    finish()

tool, built = compile_probe()
ev.check("306/precondition-the-raw-ax-witness-built",
         built.returncode == 0,
         "the witness can inspect raw AXDescription; System Events may manufacture a description "
         "when the raw attribute is absent",
         f"rc={built.returncode} stderr={(built.stderr or b'').decode('utf-8', 'replace')[:300]!r}",
         "break the witness source: the no-description assertion cannot be measured and goes red")
if built.returncode != 0:
    finish()

arrange = E.logic_window()
band = (0, 0, arrange["w"], 28) if arrange else None
band_subject = f"the title bar of the {arrange['title']!r} document window" if arrange else None
ev.check("306/precondition-a-project-window-is-open",
         arrange is not None and band is not None and bool(band_subject),
         "a project arrange window is on screen, providing the Compressor insert and the unchanged "
         "document capture",
         f"arrange={arrange!r} band={band!r}",
         "close the project: there is no Compressor insert to open and this goes red")
if band is None:
    finish()

slot_before = probe(tool, "plugin-slot", {
    "slot_label": SLOT,
    "track_label": TRACK,
    "mixer_label": MIXER,
})
ev.note("306/compressor-slot-before-opening", slot_before)
mixer_resolution = {
    "mixer_layout_areas_seen": slot_before.get("mixer_layout_areas_seen"),
    "mixer_container_count": slot_before.get("mixer_container_count"),
    "mixer_ancestor_search_bound_hit": slot_before.get("mixer_ancestor_search_bound_hit"),
}
ev.falsifiable(
    "306/precondition-exactly-one-mixer-layout-area-resolves-by-name-and-role",
    lambda observation: (observation.get("mixer_layout_areas_seen") is not None
                         and observation.get("mixer_container_count") == 1
                         and observation.get("mixer_ancestor_search_bound_hit") is False),
    mixer_resolution,
    {"mixer_layout_areas_seen": 0, "mixer_container_count": 0,
     "mixer_ancestor_search_bound_hit": False},
    "exactly one AXLayoutArea with a measured mixer label has an AXGroup with that same label as "
    "an ancestor before the named channel-strip search is allowed to begin. The Inspector shows a "
    "channel strip for the selected track and it is also an AXLayoutArea described with the mixer "
    "label, so the Mixer pane is identified by that AXGroup ancestor.",
    "close the mixer, remove its measured label, expose another matching AXLayoutArea, or exceed "
    "the 12-level ancestor bound: the harness refuses instead of opening the mixer or choosing a "
    "container by position",
)
if not (mixer_resolution["mixer_layout_areas_seen"] is not None
        and mixer_resolution["mixer_container_count"] == 1
        and mixer_resolution["mixer_ancestor_search_bound_hit"] is False):
    finish()

ev.falsifiable(
    "306/precondition-one-named-channel-strip-matches-the-track-label",
    lambda observation: observation.get("matching_strip_count") == 1,
    slot_before,
    {"matching_strip_count": 0},
    f"exactly one AXLayoutItem in the resolved mixer matches the measured track name `{TRACK}` "
    "before the Compressor search, scoped to the mixer, is allowed to descend into it; the arrange "
    "area's track header carries the same name, and choosing between them by position is not allowed",
    f"rename, remove, or duplicate `{TRACK}` inside the mixer: the harness refuses rather than "
    "guessing which channel strip owns the measured Compressor; the same-named arrange header is "
    "outside this search by design",
)
if slot_before.get("matching_strip_count") != 1:
    finish()

ev.falsifiable(
    "306/precondition-one-compressor-insert-slot-resolves-by-description",
    lambda observation: observation.get("slot_count") == 1,
    slot_before,
    {"slot_count": 0},
    f"exactly one AXGroup describes itself `Compressor` within the named `{TRACK}` channel strip; "
    "five Compressor inserts exist across channel strips, and choosing one by position is not allowed",
    "rename or remove the Compressor insert in the named strip: its scoped slot count becomes zero "
    "and this goes red",
)
if slot_before.get("slot_count") != 1:
    finish()

rec = ev.record_screen(seconds=90)
before = ev.shot("306/before", settle_region=band, window_title=arrange["title"])

driver = E.Driver()
health = driver.tool("logic_system", "health", {})
ev.falsifiable("306/the-release-artifact-answers-a-read-only-wire-request",
               lambda body: isinstance(body, dict) and bool(body), health, {},
               "the built server answered a read-only health request during this evidence run",
               "start an artifact that cannot answer MCP: the empty/error response goes red")

result = probe(tool, "compressor", {
    "slot_label": SLOT,
    "track_label": TRACK,
    "mixer_label": MIXER,
    "open_label": OPEN,
    "close_label": CLOSE,
    "view_labels": VIEW_LABELS,
    "controls_label": CONTROLS,
    "editor_label": EDITOR,
})
ev.note("306/compressor-raw-ax", result)

opening = result.get("open") if isinstance(result.get("open"), dict) else {}
pressed = opening.get("pressed_children") if isinstance(opening.get("pressed_children"), list) else []
opened_windows = opening.get("opened_windows") if isinstance(opening.get("opened_windows"), list) else []
opened = (opening.get("slot_count") == 1 and len(pressed) == 1
          and pressed[0].get("role") == "AXButton" and pressed[0].get("description") == OPEN
          and len(opened_windows) == 1)
ev.falsifiable(
    "306/the-compressor-window-opened-through-the-named-open-button",
    lambda observation: observation["opened"],
    {"opened": opened},
    {"opened": False},
    "one Compressor window appeared after a single AXButton `열기` press",
    "press no Open button, or press another child: the observed opening path goes red",
)

native_sliders = result.get("native_editor_sliders") if isinstance(result.get("native_editor_sliders"), list) else []
native_names = [name for name in slider_descriptions(native_sliders) if name]
native_settable = sum(1 for slider in native_sliders
                      if isinstance(slider, dict) and slider.get("value_settable") is True)
# NOT an exact census. Measured 2026-08-30 on two different Compressor instances in one project:
# the one on `Absolute Zero` exposes 22 sliders of which 11 claim settable values, the one on
# `Studio Grand` exposes 20 and 10. The count is a property of the instance's configuration, and an
# earlier draft asserted 22/11 because that is the pair I happened to write in an issue comment.
# What holds across both, and is the fact this harness is about, is that MOST sliders are settable
# and exactly ONE carries a name.
native_census = (
    len(native_sliders) > 0
    and native_settable > 0
    and native_settable < len(native_sliders)
)
ev.falsifiable(
    "306/native-editor-exposes-sliders-of-which-only-some-claim-settable-values",
    lambda observation: observation["ok"],
    {"ok": native_census},
    {"ok": False},
    "the native Compressor editor exposes AXSliders and only SOME of them report AXValue "
    "settable=true; the exact counts follow the instance (22/11 on one strip, 20/10 on another) "
    "so they are not asserted",
    "return no sliders, or make every slider claim settable: the invariant goes red. Note this "
    "check cannot catch a count change, deliberately - that is the instance's business",
)
native_signature = len(native_names) == 1 and native_names[0] == THRESHOLD
ev.falsifiable(
    "306/native-editor-has-exactly-one-named-slider-and-it-is-threshold",
    lambda observation: observation["ok"],
    {"ok": native_signature},
    {"ok": False},
    "among the native editor sliders, exactly one raw AXDescription is non-empty and it is `Threshold`",
    "give another native slider a description, or remove Threshold's: the exact-one signature goes red",
)

controls_selection = result.get("controls_selection") if isinstance(result.get("controls_selection"), dict) else {}
offered = controls_selection.get("items") if isinstance(controls_selection.get("items"), list) else []
offered_names = {item.get("title") or item.get("description") for item in offered if isinstance(item, dict)}
view_offers_both = (len(controls_selection.get("button_candidates", [])) == 1
                    and CONTROLS in offered_names and EDITOR in offered_names)
ev.falsifiable(
    "306/the-view-menu-offers-named-controls-and-editor-items",
    lambda observation: observation["ok"],
    {"ok": view_offers_both},
    {"ok": False},
    "the AXMenuButton `보기` exposes both the named `컨트롤` and `편집기` AXMenuItems",
    "remove either menu item: the offering check goes red before a row label can be mistaken for a slider name",
)

controls_rows = result.get("controls_rows") if isinstance(result.get("controls_rows"), list) else []
rows_label_every_parameter = all_parameters_are_row_labels(controls_rows)
row_texts, named_row_count = row_static_texts(controls_rows)
ev.falsifiable(
    "306/controls-view-puts-every-parameter-name-in-a-row-cell-static-text",
    lambda observation: observation["ok"],
    {"ok": rows_label_every_parameter},
    {"ok": False},
    "at least eleven AXRows carry cell AXStaticText, and every measured parameter name is among them",
    f"remove one parameter row label: its specific name disappears and this goes red (rows with text={named_row_count})",
)

controls_sliders = result.get("controls_sliders") if isinstance(result.get("controls_sliders"), list) else []
controls_have_no_own_descriptions = (len(controls_sliders) == 26 and all(
    isinstance(slider, dict) and slider.get("description", "") == "" for slider in controls_sliders
))
ev.falsifiable(
    "306/controls-view-sliders-have-no-own-axdescription",
    lambda observation: observation["ok"],
    {"ok": controls_have_no_own_descriptions},
    {"ok": False},
    "all 26 Controls-view sliders have an empty raw AXDescription. The name is on the row, so step 9 "
    "of set_param_verified (AXSlider matched by its own AXDescription) does NOT reach these controls",
    "attach a name to one slider, or return a non-26 census: this exact absence assertion goes red",
)

editor_selection = result.get("editor_selection") if isinstance(result.get("editor_selection"), dict) else {}
editor_after = result.get("editor_after_restore_sliders")
editor_after = editor_after if isinstance(editor_after, list) else []
restore_names = [name for name in slider_descriptions(editor_after) if name]
rows_after_restore = result.get("rows_after_restore") if isinstance(result.get("rows_after_restore"), list) else []
restored_editor = (editor_selection.get("pressed") is True
                   and restore_names == [THRESHOLD]
                   and not all_parameters_are_row_labels(rows_after_restore))
ev.check("306/the-view-switched-back-to-editor-before-close",
         restored_editor,
         "the `편집기` menu item was pressed and the AX tree returned to the native-editor signature, "
         "not merely a second copy of the Controls rows",
         f"editor_selection={editor_selection!r} named_sliders={restore_names!r} "
         f"rows_still_label_all_parameters={all_parameters_are_row_labels(rows_after_restore)!r}",
         "leave Controls selected or make the Editor item a no-op: the distinct editor signature does not return")

close = result.get("close") if isinstance(result.get("close"), dict) else {}
closed = close.get("pressed") is True and close.get("window_still_present") is False
ev.check("306/the-compressor-window-opened-by-this-run-is-closed-again",
         closed,
         "the Compressor window was closed after the asserted Editor restoration",
         f"close={close!r}",
         "leave the window open or remove its close button: this restoration check goes red")
ev.restored("306/the-compressor-view-and-window-are-back-where-they-started",
            restored_editor and closed,
            f"editor_restored={restored_editor!r} close={close!r}")

after = ev.shot("306/after", settle_region=band, window_title=arrange["title"])
ev.visual("306/switching-the-plugin-view-and-closing-it-does-not-change-the-project",
          before["file"], after["file"], band, subject=band_subject, expect_change=False,
          why="the harness switched a temporary plug-in view, restored it, and attempted no Compressor or project write")

driver.close()
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
