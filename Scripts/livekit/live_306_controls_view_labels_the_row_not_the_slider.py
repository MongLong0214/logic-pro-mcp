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
On Korean Logic 12.x, Compressor's native editor exposes 22 sliders on one instance (11 settable)
and 20 on another (10 settable) in the same project - the count follows the instance's
configuration. On both, only `Threshold` has a raw AXDescription. The `보기` menu offers `컨트롤`
and `편집기`. In Controls view, parameter names live in AXStaticText inside AXCells of AXRows; the
controls beside them can be AXSlider, AXRadioButton, or AXPopUpButton. The measured Controls view
has 26 sliders. In the repeated witness, 23 AXDescription reads establish that their sliders have
no name of their own; three return kAXErrorFailure instead. Those three sliders might carry names:
this harness records that gap rather than treating a failed read as absence.

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
CONTROL_ROLES = {"AXSlider", "AXRadioButton", "AXPopUpButton"}
DESCRIPTION_READ_SUCCEEDED = {"success_with_value", "success_without_value"}

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


def derived_witness(observation, **changes):
    """Copy a raw witness before changing one fact for a same-shape counterexample."""
    counterexample = dict(observation) if isinstance(observation, dict) else {}
    counterexample.update(changes)
    return counterexample


def copied_nodes(nodes):
    return [dict(node) if isinstance(node, dict) else node for node in nodes] if isinstance(nodes, list) else []


def descriptions_without(nodes, description):
    counterexample = copied_nodes(nodes)
    for node in counterexample:
        if isinstance(node, dict) and node.get("description") == description:
            node["description"] = ""
    return counterexample


def sliders_with_every_field(sliders, field, value):
    counterexample = copied_nodes(sliders)
    for slider in counterexample:
        if isinstance(slider, dict):
            slider[field] = value
    return counterexample


def mixer_layout_resolves_by_name_and_role(witness):
    return (
        isinstance(witness, dict)
        and witness.get("mixer_layout_areas_seen") is not None
        and witness.get("mixer_container_count") == 1
        and witness.get("mixer_ancestor_search_bound_hit") is False
    )


def compressor_window_opened_through_named_button(opening):
    if not isinstance(opening, dict):
        return False
    pressed = opening.get("pressed_children") if isinstance(opening.get("pressed_children"), list) else []
    opened_windows = opening.get("opened_windows") if isinstance(opening.get("opened_windows"), list) else []
    return (
        opening.get("slot_count") == 1
        and len(pressed) == 1
        and pressed[0].get("role") == "AXButton"
        and pressed[0].get("description") == OPEN
        and len(opened_windows) == 1
    )


def opening_with_pressed_description(opening, description):
    """Change the selected button's label while retaining the observed opening shape."""
    counterexample = derived_witness(opening)
    pressed = copied_nodes(counterexample.get("pressed_children"))
    if len(pressed) == 1 and isinstance(pressed[0], dict):
        pressed[0]["description"] = description
    counterexample["pressed_children"] = pressed
    return counterexample


def native_editor_has_partly_settable_sliders(sliders):
    if not isinstance(sliders, list):
        return False
    settable = sum(1 for slider in sliders
                   if isinstance(slider, dict) and slider.get("value_settable") is True)
    return 0 < settable < len(sliders)


def native_editor_has_only_threshold_named(sliders):
    return isinstance(sliders, list) and [name for name in slider_descriptions(sliders) if name] == [THRESHOLD]


def view_menu_offers_controls_and_editor(selection):
    if not isinstance(selection, dict):
        return False
    items = selection.get("items") if isinstance(selection.get("items"), list) else []
    names = {item.get("title") or item.get("description") for item in items if isinstance(item, dict)}
    candidates = selection.get("button_candidates")
    return isinstance(candidates, list) and len(candidates) == 1 and CONTROLS in names and EDITOR in names


def view_menu_without_item(selection, label):
    counterexample = derived_witness(selection)
    items = copied_nodes(counterexample.get("items"))
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("title") == label:
            item["title"] = ""
        if item.get("description") == label:
            item["description"] = ""
    counterexample["items"] = items
    return counterexample


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
    """Every expected name shares an AXCell with a reported control, not just any row text."""
    texts, named_rows = row_static_texts(rows)
    def paired(name):
        for row in rows if isinstance(rows, list) else []:
            cells = row.get("cells") if isinstance(row, dict) else []
            for cell in cells if isinstance(cells, list) else []:
                if not isinstance(cell, dict):
                    continue
                cell_texts = cell.get("static_texts")
                control_roles = cell.get("control_roles")
                if (isinstance(cell_texts, list) and name in cell_texts
                        and isinstance(control_roles, list)
                        and any(role in CONTROL_ROLES for role in control_roles)):
                    return True
        return False
    return named_rows >= len(PARAMETERS) and all(name in texts and paired(name) for name in PARAMETERS)


def rows_without_parameter_pair(rows, parameter):
    counterexample = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            counterexample.append(row)
            continue
        copied_row = dict(row)
        cells = row.get("cells")
        if isinstance(cells, list):
            copied_cells = []
            for cell in cells:
                if not isinstance(cell, dict):
                    copied_cells.append(cell)
                    continue
                copied_cell = dict(cell)
                texts = cell.get("static_texts")
                if isinstance(texts, list):
                    copied_cell["static_texts"] = [text for text in texts if text != parameter]
                copied_cells.append(copied_cell)
            copied_row["cells"] = copied_cells
        counterexample.append(copied_row)
    return counterexample


# A completed AXDescription read can establish absence in two ways: the raw read succeeded with an
# empty value, or AX reports one of these two absence answers. kAXErrorFailure is deliberately not
# here. The repeated Controls-view witness returns it for three live AXSliders, so it proves neither
# the presence nor the absence of a slider-owned name.
# PyObjC's Quartz bridge does not expose these AXError constants. Keep each SDK name and value
# together here so the raw values from the Swift witness remain auditable against AXError.h.
K_AX_ERROR_NO_VALUE = -25212
K_AX_ERROR_ATTRIBUTE_UNSUPPORTED = -25205
AX_ABSENCE_ERRORS = frozenset({K_AX_ERROR_NO_VALUE, K_AX_ERROR_ATTRIBUTE_UNSUPPORTED})
AX_DESCRIPTION = "AXDescription"


def controls_slider_description_census(sliders):
    """Split name reads by what the Accessibility result actually established.

    A failed read belongs in the unevaluated gap unless AX itself returned an absence answer. That
    keeps a claim about the evaluated sliders from silently becoming a claim about unreadable ones.
    """
    census = {
        # Keep these summary fields first: falsifiable receipts retain a bounded representation of
        # their observation, and the count plus codes are the evidence boundary this run must show.
        "slider_count": len(sliders) if isinstance(sliders, list) else None,
        "evaluated_count": 0,
        "unevaluated_count": 0,
        "unevaluated_error_codes": [],
        "unclassified_count": 0,
        "evaluated_sliders": [],
        "unevaluated_sliders": [],
        "unclassified_sliders": [],
        "sliders": copied_nodes(sliders),
    }
    for slider in sliders if isinstance(sliders, list) else []:
        if not isinstance(slider, dict):
            census["unclassified_sliders"].append(slider)
            continue
        status = slider.get("description_status")
        if status in DESCRIPTION_READ_SUCCEEDED:
            census["evaluated_sliders"].append(slider)
            continue
        if status == "failed":
            error = slider.get("description_error")
            if error in AX_ABSENCE_ERRORS:
                census["evaluated_sliders"].append(slider)
            else:
                census["unevaluated_sliders"].append(slider)
                census["unevaluated_error_codes"].append(error)
            continue
        census["unclassified_sliders"].append(slider)

    census["evaluated_count"] = len(census["evaluated_sliders"])
    census["unevaluated_count"] = len(census["unevaluated_sliders"])
    census["unclassified_count"] = len(census["unclassified_sliders"])
    return census


def evaluated_controls_sliders_carry_no_name_of_their_own(census):
    """Every evaluated Controls-view slider has no name, and evaluation was non-vacuous.

    The exact 26-slider census remains part of the measured surface. Unknown statuses are rejected
    too: only AX's success and its two absence answers can place a slider in the evaluated set.
    """
    if not isinstance(census, dict) or census.get("slider_count") != 26:
        return False
    evaluated = census.get("evaluated_sliders")
    unevaluated = census.get("unevaluated_sliders")
    unclassified = census.get("unclassified_sliders")
    if not all(isinstance(group, list) for group in (evaluated, unevaluated, unclassified)):
        return False
    if census.get("evaluated_count") != len(evaluated) or census.get("unevaluated_count") != len(unevaluated):
        return False
    if census.get("unclassified_count") != len(unclassified) or unclassified:
        return False
    if len(evaluated) + len(unevaluated) != 26 or not evaluated:
        return False
    return all(isinstance(slider, dict) and slider.get("description", "") == ""
               for slider in evaluated)


def unevaluated_controls_slider_gap_is_recorded(census):
    """Verify that the receipt preserves, but does not condemn, the unreadable subset."""
    if not isinstance(census, dict):
        return False
    unevaluated = census.get("unevaluated_sliders")
    error_codes = census.get("unevaluated_error_codes")
    if not isinstance(unevaluated, list) or not isinstance(error_codes, list):
        return False
    return (
        census.get("unevaluated_count") == len(unevaluated) == len(error_codes)
        and error_codes == [slider.get("description_error") if isinstance(slider, dict) else None
                            for slider in unevaluated]
    )


def census_with_one_evaluated_slider_named(census, description):
    """Make a coherent named-slider observation without changing the census's structure."""
    sliders = copied_nodes(census.get("sliders") if isinstance(census, dict) else [])
    for slider in sliders:
        if not isinstance(slider, dict):
            continue
        status = slider.get("description_status")
        if status in DESCRIPTION_READ_SUCCEEDED or (
                status == "failed" and slider.get("description_error") in AX_ABSENCE_ERRORS):
            # A successful non-empty result is a real observation a slider could make. Changing the
            # status with the text avoids a contradictory synthetic record that only fails a shape
            # guard instead of the evaluated-name condition.
            slider["description"] = description
            slider["description_status"] = "success_with_value"
            slider["description_error"] = None
            break
    return controls_slider_description_census(sliders)


def census_with_misrecorded_unevaluated_gap(census):
    """Remove or invent one error code so the gap receipt has to reconcile with its census."""
    counterexample = derived_witness(census)
    error_codes = list(counterexample.get("unevaluated_error_codes", []))
    if error_codes:
        error_codes.pop()
    else:
        error_codes.append("counterexample error")
    counterexample["unevaluated_error_codes"] = error_codes
    return counterexample


def raw_ax_failure_accounting_observation(result, census, native_census):
    """Put the raw failures beside every census that may explain them.

    Measured 2026-08-30: the failures this run could not explain were on NATIVE EDITOR sliders, not
    Controls-view ones. Both views are censused the same way, so both belong here — an accounting
    that knows about one of two populations reports an unexplained failure for a read it did in
    fact classify.
    """
    failures = result.get("ax_read_failures", []) if isinstance(result, dict) else []
    return {
        "ax_read_failure_count": len(failures) if isinstance(failures, list) else None,
        "controls_slider_unevaluated_count": census.get("unevaluated_count") if isinstance(census, dict) else None,
        "controls_slider_unevaluated_error_codes": census.get("unevaluated_error_codes") if isinstance(census, dict) else None,
        "native_slider_unevaluated_count": native_census.get("unevaluated_count") if isinstance(native_census, dict) else None,
        "native_slider_unevaluated_error_codes": native_census.get("unevaluated_error_codes") if isinstance(native_census, dict) else None,
        "ax_read_failures": failures,
        "controls_slider_census": census,
        "native_slider_census": native_census,
    }


def every_raw_ax_read_failure_is_accounted_for(observation):
    """Accept only the specific unreadable slider descriptions counted by this harness.

    A raw read elsewhere remains unexplained even if it happens to have the same error code. Exact
    element-and-code pairing prevents a broad "-25200 is okay" exception from swallowing it.
    """
    if not isinstance(observation, dict):
        return False
    failures = observation.get("ax_read_failures")
    unevaluated = []
    for key in ("controls_slider_census", "native_slider_census"):
        census = observation.get(key)
        rows = census.get("unevaluated_sliders") if isinstance(census, dict) else None
        if not isinstance(rows, list):
            return False
        unevaluated.extend(rows)
    if not isinstance(failures, list):
        return False

    counted = Counter()
    for slider in unevaluated:
        if not isinstance(slider, dict) or slider.get("description_status") != "failed":
            return False
        element_id = slider.get("element_id")
        if not isinstance(element_id, str) or not element_id:
            return False
        counted[(element_id, slider.get("description_error"))] += 1

    reported = Counter()
    for failure in failures:
        if not isinstance(failure, dict) or failure.get("attribute") != AX_DESCRIPTION:
            return False
        element_id = failure.get("element_id")
        if not isinstance(element_id, str) or not element_id:
            return False
        if failure.get("code") != failure.get("status"):
            return False
        reported[(element_id, failure.get("code"))] += 1
    return reported == counted


def accounting_with_unexplained_title_failure(observation):
    """Add a plausible AXTitle failure so accounting cannot pass by ignoring raw failures."""
    counterexample = derived_witness(observation)
    failures = copied_nodes(counterexample.get("ax_read_failures"))
    census = counterexample.get("controls_slider_census")
    unevaluated = census.get("unevaluated_sliders") if isinstance(census, dict) else []
    source = unevaluated[0] if isinstance(unevaluated, list) and unevaluated else {}
    element_id = source.get("element_id") if isinstance(source, dict) else "counterexample-slider"
    failures.append({
        "attribute": "AXTitle",
        "status": K_AX_ERROR_NO_VALUE,
        "code": K_AX_ERROR_NO_VALUE,
        "element_id": element_id,
        "element_role": "AXSlider",
        "element_title": "<unreadable>",
        "read_site": "counterexample",
    })
    counterexample["ax_read_failures"] = failures
    counterexample["ax_read_failure_count"] = len(failures)
    return counterexample


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
ev.falsifiable(
    "306/precondition-exactly-one-mixer-layout-area-resolves-by-name-and-role",
    mixer_layout_resolves_by_name_and_role,
    slot_before,
    derived_witness(slot_before, mixer_container_count=0),
    "exactly one AXLayoutArea with a measured mixer label has an AXGroup with that same label as "
    "an ancestor before the named channel-strip search is allowed to begin. The Inspector shows a "
    "channel strip for the selected track and it is also an AXLayoutArea described with the mixer "
    "label, so the Mixer pane is identified by that AXGroup ancestor.",
    "close the mixer, remove its measured label, expose another matching AXLayoutArea, or exceed "
    "the 12-level ancestor bound: the harness refuses instead of opening the mixer or choosing a "
    "container by position",
)
if not mixer_layout_resolves_by_name_and_role(slot_before):
    finish()

ev.falsifiable(
    "306/precondition-one-named-channel-strip-matches-the-track-label",
    lambda observation: observation.get("matching_strip_count") == 1,
    slot_before,
    derived_witness(slot_before, matching_strip_count=0),
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
    derived_witness(slot_before, slot_count=0),
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
health_counterexample = derived_witness(health, _transport_error=None)
ev.falsifiable("306/the-release-artifact-answers-a-read-only-wire-request",
               E.artifact_answered, health, health_counterexample,
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

controls_sliders = result.get("controls_sliders") if isinstance(result.get("controls_sliders"), list) else []
controls_slider_census = controls_slider_description_census(controls_sliders)
# The native editor's sliders get the same census. It is not asserted on — the native view's naming
# is checked elsewhere by its own signature — but its unreadable descriptions have to be counted, or
# the raw-failure accounting reports a failure this run did in fact classify. Measured: the two
# failures that went unexplained were native-editor sliders, not Controls-view ones.
# Both native-editor reads: the one before the view switch and the one after the restore. The
# harness reads that view twice, so censusing it once leaves the second read's unreadable
# descriptions unaccounted and the accounting reports a failure it did classify.
native_slider_census = controls_slider_description_census(
    (result.get("native_editor_sliders") if isinstance(result.get("native_editor_sliders"), list) else [])
    + (result.get("editor_after_restore_sliders")
       if isinstance(result.get("editor_after_restore_sliders"), list) else []))
ev.falsifiable(
    "306/controls-view-evaluated-sliders-have-no-own-axdescription",
    evaluated_controls_sliders_carry_no_name_of_their_own,
    controls_slider_census,
    census_with_one_evaluated_slider_named(controls_slider_census, "counterexample description"),
    f"of the {controls_slider_census['slider_count']} Controls-view sliders, every one of the "
    f"{controls_slider_census['evaluated_count']} whose AXDescription could be evaluated carries no "
    f"name of its own; evaluation is non-vacuous. The {controls_slider_census['unevaluated_count']} "
    "unevaluated sliders are recorded separately because they might carry names and this run cannot say.",
    "give one currently evaluated slider a successful non-empty AXDescription: it stays in the "
    "evaluated set, so the no-name condition itself goes red rather than a structural guard doing it",
)
ev.falsifiable(
    "306/controls-view-slider-axdescription-unevaluated-gap-is-recorded",
    unevaluated_controls_slider_gap_is_recorded,
    controls_slider_census,
    census_with_misrecorded_unevaluated_gap(controls_slider_census),
    f"{controls_slider_census['unevaluated_count']} Controls-view sliders could not be evaluated for "
    f"AXDescription (error codes {controls_slider_census['unevaluated_error_codes']!r}); they might "
    "carry names and this run cannot say. This is a recorded measured gap, not an assertion that the "
    "gap is a defect or must be zero.",
    "remove or invent an unevaluated error code: the gap no longer reconciles with the slider census "
    "and this receipt goes red; a changed measured gap remains recorded rather than condemned",
)

raw_ax_failure_accounting = raw_ax_failure_accounting_observation(
    result, controls_slider_census, native_slider_census)
ev.falsifiable(
    "306/raw-ax-probe-completed-its-search",
    every_raw_ax_read_failure_is_accounted_for,
    raw_ax_failure_accounting,
    accounting_with_unexplained_title_failure(raw_ax_failure_accounting),
    "no raw AX read failure this run has not explained: every failure is an AXDescription failure "
    "on a Controls-view slider counted in the unevaluated census. This does not claim there were no "
    "failures; it rejects a failure anywhere else or on any other attribute.",
    "make AXTitle fail, or make AXDescription fail outside a Controls-view slider: no unevaluated "
    "slider census entry accounts for it and this goes red",
)
if not every_raw_ax_read_failure_is_accounted_for(raw_ax_failure_accounting):
    finish()

opening = result.get("open") if isinstance(result.get("open"), dict) else {}
ev.falsifiable(
    "306/the-compressor-window-opened-through-the-named-open-button",
    compressor_window_opened_through_named_button,
    opening,
    opening_with_pressed_description(opening, "not the Open label"),
    "one Compressor window appeared after a single AXButton `열기` press",
    "change the pressed AXButton's description while retaining the observed slot and window: the "
    "named-open condition goes red",
)

native_sliders = result.get("native_editor_sliders") if isinstance(result.get("native_editor_sliders"), list) else []
# NOT an exact census. Measured 2026-08-30 on two different Compressor instances in one project:
# the one on `Absolute Zero` exposes 22 sliders of which 11 claim settable values, the one on
# `Studio Grand` exposes 20 and 10. The count is a property of the instance's configuration, and an
# earlier draft asserted 22/11 because that is the pair I happened to write in an issue comment.
# What holds across both, and is the fact this harness is about, is that exactly HALF of the sliders
# are settable and exactly ONE carries a name.
ev.falsifiable(
    "306/native-editor-exposes-sliders-of-which-only-some-claim-settable-values",
    native_editor_has_partly_settable_sliders,
    native_sliders,
    sliders_with_every_field(native_sliders, "value_settable", True),
    "the native Compressor editor exposes AXSliders and only SOME of them report AXValue "
    "settable=true; the exact counts follow the instance (22/11 on one strip, 20/10 on another) "
    "so they are not asserted",
    "return no sliders, or make every slider claim settable: the invariant goes red. Note this "
    "check cannot catch a count change, deliberately - that is the instance's business",
)
ev.falsifiable(
    "306/native-editor-has-exactly-one-named-slider-and-it-is-threshold",
    native_editor_has_only_threshold_named,
    native_sliders,
    descriptions_without(native_sliders, THRESHOLD),
    "among the native editor sliders, exactly one raw AXDescription is non-empty and it is `Threshold`",
    "give another native slider a description, or remove Threshold's: the exact-one signature goes red",
)

controls_selection = result.get("controls_selection") if isinstance(result.get("controls_selection"), dict) else {}
ev.falsifiable(
    "306/the-view-menu-offers-named-controls-and-editor-items",
    view_menu_offers_controls_and_editor,
    controls_selection,
    view_menu_without_item(controls_selection, CONTROLS),
    "the AXMenuButton `보기` exposes both the named `컨트롤` and `편집기` AXMenuItems",
    "remove either menu item: the offering check goes red before a row label can be mistaken for a slider name",
)

controls_rows = result.get("controls_rows") if isinstance(result.get("controls_rows"), list) else []
row_texts, named_row_count = row_static_texts(controls_rows)
ev.falsifiable(
    "306/controls-view-puts-every-parameter-name-in-a-row-cell-static-text",
    all_parameters_are_row_labels,
    controls_rows,
    rows_without_parameter_pair(controls_rows, "Threshold:"),
    "at least eleven AXRows carry cell AXStaticText, and every measured parameter name shares a cell "
    "with an AXSlider, AXRadioButton, or AXPopUpButton",
    f"remove one parameter row label or its cell's control: its specific pairing disappears and this "
    f"goes red (rows with text={named_row_count})",
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
