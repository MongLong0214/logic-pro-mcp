#!/usr/bin/env python3
"""Live qualification for Channel EQ's verified named-band write operation.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_301_eq_band_write_lands_and_rolls_back.py <worktree> <full-40-char-head-sha>

This is deliberately a harness, not a claim that a write has landed. It drives the release artifact
against the named `Studio Grand` strip, moves `Peak 1 Gain` a visible raw distance, asks Logic for a
dB rendering, restores the starting raw value, and checks that `Peak 2 Gain` did not move. If the
walk does not land, that is the result: the checks stay red and the evidence records the response.
Do not tune a target or a predicate after a red run merely to make this file pass.

The prior raw-AX measurement established only the ingredients for this run: Channel EQ gain has raw
AXValue 0...480; a raw assignment advances one increment/decrement; and AXValueDescription is
Logic's own dB rendering (262 was observed as `+2.2 dB`). It did not establish an end-to-end write.
In particular, no Hz/dB conversion is calculated here. The display-unit request below succeeds only
when Logic itself returns the requested dB string.

The tiny raw witness is read-only: it opens the one globally named Channel EQ only to seed an exact
zero-step wire read. That wire response is the recorded before-value/display; all operations that can
write, including the zero-step read, use E.Driver() and the release artifact over MCP.
"""

import copy
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


# What this harness proves, for `harness_evidence_coverage.py`.
#
# The request crosses the public dispatcher, and the only parameter write algorithm it exercises is
# the named-band increment walk. Claiming the catalogue or the AX channel would be wider than this
# run: neither is driven as an independently observable contract here.
COVERS = [
    "Sources/LogicProMCP/Plugins/SliderIncrementWalk.swift",
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

TRACK_NAME = "Studio Grand"
SLOT_NAME = "Channel EQ"
# The mixer label family the policy already owns, so this is not a second Korean literal.
MIXER_LABELS = E.label_set("mixerNamedElement")
BAND = "Peak 1"
PARAMETER = "Gain"
PEAK_1_GAIN = "Peak 1 Gain"
PEAK_2_GAIN = "Peak 2 Gain"
RAW_UNIT = "raw_ax_value"
DISPLAY_UNIT = "dB"
MODE = "duplicate_applyback"
RAW_MIN = 0.0
RAW_MAX = 480.0
RAW_TOLERANCE = 0.0
VISIBLE_RAW_DISTANCE = 40.0
OUT_OF_RANGE_RAW = RAW_MAX + 1.0

# These are the Korean labels actually measured for the stock Channel EQ window on this host. There
# is intentionally no translated fallback: an unmeasured locale must fail closed rather than press
# a lookalike control. The plug-in and band names themselves are the measured AX descriptions.
OPEN = "열기"
CLOSE = "닫기"
BYPASS_LABELS = E.label_set("pluginBypassControl")


def finish(code=1):
    if driver is not None:
        driver.close()
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(code)


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def close_enough(actual, expected, tolerance=RAW_TOLERANCE):
    return number(actual) and number(expected) and abs(float(actual) - float(expected)) <= tolerance


def derived_witness(observation, **changes):
    """Preserve the observed response shape while replacing one load-bearing fact."""
    counterexample = copy.deepcopy(observation) if isinstance(observation, dict) else {}
    counterexample.update(changes)
    return counterexample


def nested_witness(observation, key, **changes):
    counterexample = derived_witness(observation)
    nested = counterexample.get(key)
    nested = copy.deepcopy(nested) if isinstance(nested, dict) else {}
    nested.update(changes)
    counterexample[key] = nested
    return counterexample


def compile_probe():
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_plugin_menu_probe.swift")
    tool = os.path.join(ev.dir, "ax_plugin_menu_probe")
    result = subprocess.run(["swiftc", "-O", source, "-o", tool], capture_output=True)
    return tool, result


def raw_probe(tool):
    """Read the AX witness without performing an AX value write.

    `runChannelEQ` opens and closes the uniquely named insert, but its only slider actions are reads.
    It seeds the exact raw value supplied to the subsequent zero-step MCP read; it never drives the
    operation under test.
    """
    # Scoped by track and mixer. Unscoped, a `Channel EQ` search finds TWO — the mixer strip's
    # insert and the Inspector's copy of the same strip for the selected track — and the witness
    # refuses on the ambiguity, correctly but uselessly. `Studio Grand` is the strip that carries
    # the Channel EQ; `Absolute Zero` carries two Compressors and none.
    config = {
        "slot_label": SLOT_NAME,
        "track_label": TRACK_NAME,
        "mixer_label": MIXER_LABELS,
        "open_label": OPEN,
        "close_label": CLOSE,
        "bypass_labels": BYPASS_LABELS,
    }
    result = subprocess.run([tool, "channel-eq", json.dumps(config, ensure_ascii=False)],
                            capture_output=True, text=True)
    try:
        body = json.loads(result.stdout or "{}")
    except ValueError:
        body = {"_raw": (result.stdout or result.stderr)[:400]}
    body["_returncode"] = result.returncode
    return body


def raw_slider(body, description):
    sliders = body.get("sliders") if isinstance(body, dict) else None
    matches = [slider for slider in sliders or []
               if isinstance(slider, dict) and slider.get("description") == description]
    return matches[0] if len(matches) == 1 else {}


def raw_witness_is_complete(body):
    if not isinstance(body, dict) or body.get("outcome") != "searched":
        return False
    opening = body.get("open") if isinstance(body.get("open"), dict) else {}
    if opening.get("slot_count") != 1:
        return False
    for description in (PEAK_1_GAIN, PEAK_2_GAIN):
        slider = raw_slider(body, description)
        if not (
            slider.get("value_status") == "success_with_value"
            and number(slider.get("value"))
            and slider.get("value_description_status") == "success_with_value"
            and isinstance(slider.get("value_description"), str)
            and slider["value_description"].strip()
        ):
            return False
    return True


def raw_witness_without_peak_1_display(body):
    counterexample = derived_witness(body)
    sliders = counterexample.get("sliders")
    sliders = copy.deepcopy(sliders) if isinstance(sliders, list) else []
    for slider in sliders:
        if isinstance(slider, dict) and slider.get("description") == PEAK_1_GAIN:
            slider["value_description"] = ""
            break
    counterexample["sliders"] = sliders
    return counterexample


def project_is_open(project):
    data = project.get("data") if isinstance(project, dict) else None
    return (
        isinstance(data, dict)
        and isinstance(data.get("filePath"), str)
        and bool(data["filePath"].strip())
    )


def named_track_is_live(tracks):
    rows = tracks.get("data") if isinstance(tracks, dict) else None
    matches = [row for row in rows or []
               if isinstance(row, dict) and row.get("name") == TRACK_NAME]
    return (
        isinstance(tracks, dict)
        and tracks.get("readable") is True
        and len(matches) == 1
        and isinstance(matches[0].get("id"), int)
        and isinstance(matches[0].get("track_ref"), str)
        and bool(matches[0]["track_ref"].strip())
    )


def inventory_has_one_channel_eq(inventory):
    plugins = inventory.get("plugins") if isinstance(inventory, dict) else None
    matches = [plugin for plugin in plugins or []
               if isinstance(plugin, dict) and plugin.get("name") == SLOT_NAME]
    return (
        isinstance(inventory, dict)
        and inventory.get("state") == "A"
        and inventory.get("complete") is True
        and len(matches) == 1
        and isinstance(matches[0].get("insert"), int)
    )


def inventory_without_channel_eq(inventory):
    counterexample = derived_witness(inventory)
    plugins = counterexample.get("plugins")
    plugins = copy.deepcopy(plugins) if isinstance(plugins, list) else []
    for plugin in plugins:
        if isinstance(plugin, dict) and plugin.get("name") == SLOT_NAME:
            plugin["name"] = "not Channel EQ"
            break
    counterexample["plugins"] = plugins
    return counterexample


def state_a(response):
    return (
        isinstance(response, dict)
        and response.get("state") == "A"
        and response.get("success") is True
        and response.get("verified") is True
        and response.get("operation") == "logic_plugins.set_eq_band_verified"
    )


def zero_step_read_landed(observation):
    response = observation.get("response") if isinstance(observation, dict) else None
    wanted = observation.get("seed_raw") if isinstance(observation, dict) else None
    return (
        state_a(response)
        and close_enough(response.get("requested_normalized"), wanted)
        and close_enough(response.get("observed_normalized"), wanted)
        and response.get("walk_steps") == 0
        and isinstance(response.get("observed_display"), str)
        and bool(response["observed_display"].strip())
    )


def raw_walk_landed(observation):
    response = observation.get("response") if isinstance(observation, dict) else None
    target = observation.get("target_raw") if isinstance(observation, dict) else None
    return (
        state_a(response)
        and close_enough(response.get("requested_normalized"), target)
        and close_enough(response.get("observed_normalized"), target)
        and response.get("tolerance") == RAW_TOLERANCE
        and isinstance(response.get("walk_steps"), int)
        and response["walk_steps"] > 1
    )


def raw_one_step_witness(observation, before_raw, direction):
    counterexample = nested_witness(
        observation,
        "response",
        observed_normalized=before_raw + direction,
        walk_steps=1,
    )
    return counterexample


def display_changed_with_raw_value(observation):
    before = observation.get("before") if isinstance(observation, dict) else None
    after = observation.get("after") if isinstance(observation, dict) else None
    return (
        isinstance(before, dict)
        and isinstance(after, dict)
        and state_a(after)
        and number(before.get("observed_normalized"))
        and number(after.get("observed_normalized"))
        and before.get("observed_normalized") != after.get("observed_normalized")
        and isinstance(before.get("observed_display"), str)
        and isinstance(after.get("observed_display"), str)
        and bool(before["observed_display"].strip())
        and bool(after["observed_display"].strip())
        and before["observed_display"] != after["observed_display"]
    )


def raw_move_with_stale_display(observation):
    counterexample = derived_witness(observation)
    before = counterexample.get("before")
    after = copy.deepcopy(counterexample.get("after")) if isinstance(counterexample.get("after"), dict) else {}
    if isinstance(before, dict):
        after["observed_display"] = before.get("observed_display")
    counterexample["after"] = after
    return counterexample


def display_request_landed(observation):
    response = observation.get("response") if isinstance(observation, dict) else None
    wanted_display = observation.get("wanted_display") if isinstance(observation, dict) else None
    wanted_value = observation.get("wanted_value") if isinstance(observation, dict) else None
    return (
        state_a(response)
        and close_enough(response.get("requested_normalized"), wanted_value)
        and response.get("requested_display") == wanted_display
        and response.get("observed_display") == wanted_display
        and response.get("display_unit") == DISPLAY_UNIT
    )


def restored_to_before(observation):
    response = observation.get("response") if isinstance(observation, dict) else None
    before = observation.get("before_raw") if isinstance(observation, dict) else None
    return (
        state_a(response)
        and close_enough(response.get("requested_normalized"), before)
        and close_enough(response.get("observed_normalized"), before)
        and response.get("tolerance") == RAW_TOLERANCE
    )


def out_of_range_refused_without_motion(observation):
    response = observation.get("response") if isinstance(observation, dict) else None
    before = observation.get("before") if isinstance(observation, dict) else None
    after = observation.get("after") if isinstance(observation, dict) else None
    return (
        isinstance(response, dict)
        and response.get("state") == "C"
        and response.get("write_attempted") is False
        and isinstance(before, dict)
        and state_a(after)
        and close_enough(before.get("value"), after.get("observed_normalized"))
        and after.get("walk_steps") == 0
        and before.get("value_description") == after.get("observed_display")
    )


def other_band_is_unchanged(observation):
    before = observation.get("before") if isinstance(observation, dict) else None
    after = observation.get("response") if isinstance(observation, dict) else None
    return (
        isinstance(before, dict)
        and state_a(after)
        and close_enough(before.get("value"), after.get("observed_normalized"))
        and after.get("walk_steps") == 0
        and isinstance(before.get("value_description"), str)
        and before.get("value_description") == after.get("observed_display")
    )


def set_eq(value, unit, target_ref, insert, project_path, band=BAND, parameter=PARAMETER):
    """The only path that drives the verified operation: MCP `params`, not direct AX."""
    return driver.tool("logic_plugins", "set_eq_band_verified", {
        "target_ref": target_ref,
        "insert": insert,
        "band": band,
        "parameter": parameter,
        "value": value,
        "unit": unit,
        "mode": MODE,
        "project_expected_path": project_path,
    })


def safe_set_eq(value, unit, target_ref, insert, project_path, band=BAND, parameter=PARAMETER):
    try:
        return set_eq(value, unit, target_ref, insert, project_path, band, parameter)
    except Exception as exc:  # noqa: BLE001 - retain a transport failure as the observation
        return {"driver_exception": repr(exc)}


# `None` is the only completed clear scan. A detected modal is a dict and an interrupted scan is
# E.MODAL_CANNOT_TELL; both are deliberately refused before a raw AX read or MCP operation.
modal = E.blocking_modal()
ev.check(
    "301/precondition-no-blocking-modal",
    modal is None,
    "a completed CoreGraphics/AX modal scan found no Logic blocker before the run reads or writes",
    f"blocking_modal={modal!r}",
    "show Logic's audio-hardware alert, or make one detector unreadable: this refuses on either a "
    "detected modal or E.MODAL_CANNOT_TELL",
)
if modal is not None:
    finish()

policy_ready = isinstance(BYPASS_LABELS, list) and bool(BYPASS_LABELS)
ev.check(
    "301/precondition-the-measured-korean-window-labels-remain-in-policy",
    policy_ready,
    "the policy still supplies the measured bypass-label family used by the read-only witness",
    f"open={OPEN!r} close={CLOSE!r} bypass_labels={BYPASS_LABELS!r}",
    "remove the measured bypass label family: the harness refuses instead of opening a window with "
    "an unreviewed selector",
)
if not policy_ready:
    finish()

driver = E.Driver()
project = driver.resource("logic://project/info") or {}
ev.falsifiable(
    "301/precondition-a-saved-project-is-open",
    project_is_open,
    project,
    nested_witness(project, "data", filePath=""),
    "logic://project/info supplies a non-empty current-document filePath for the write boundary",
    "close the project or open an unsaved one: filePath is absent and the write cannot be bounded",
)
if not project_is_open(project):
    finish()
project_path = project["data"]["filePath"].strip()

# `logic://tracks` is cache-served and reports `readable: False` with placeholder names until a
# live AX track read has happened — measured today, it answers `Track 1…26` with
# `reason: track_names_synthesised_from_project_file` on a project whose tracks are named
# `Absolute Zero`, `Audio 1`, `Studio Grand`. That is the resource being honest, not a defect, and
# it means a harness that reads it cold is reading synthesised names. Prime it the way a caller
# would, and record that the priming happened so a reader can see the read is live.
refresh = driver.tool("logic_system", "refresh_cache", {}) or {}
ev.check(
    "301/precondition-the-live-track-read-was-primed",
    isinstance(refresh, dict) and refresh.get("refreshed") is True,
    "system.refresh_cache reports a completed refresh before any track name is trusted",
    f"refresh={refresh!r}",
    "skip the refresh: logic://tracks answers synthesised placeholder names and the strip cannot be "
    "resolved by name",
)
tracks = driver.resource("logic://tracks") or {}
track_counterexample = derived_witness(tracks)
counter_rows = copy.deepcopy(track_counterexample.get("data")) if isinstance(track_counterexample.get("data"), list) else []
for row in counter_rows:
    if isinstance(row, dict) and row.get("name") == TRACK_NAME:
        row["name"] = "not Studio Grand"
        break
track_counterexample["data"] = counter_rows
ev.falsifiable(
    "301/precondition-studio-grand-resolves-once-by-name",
    named_track_is_live,
    tracks,
    track_counterexample,
    "one live track row is exactly named `Studio Grand` and carries a session-stable track_ref; no "
    "hard-coded strip position is used",
    "rename or duplicate Studio Grand: the named target is absent or ambiguous and the run refuses",
)
if not named_track_is_live(tracks):
    finish()

track_rows = tracks["data"]
track = next(row for row in track_rows if row.get("name") == TRACK_NAME)
track_ref = track["track_ref"]

# get_inventory currently accepts an index. This is the id returned by the uniquely name-resolved
# live row above, never an authored strip position; all later mutating calls use `track_ref`.
inventory = driver.tool("logic_plugins", "get_inventory", {"track": track["id"]})
ev.falsifiable(
    "301/precondition-studio-grand-resolves-exactly-one-channel-eq-insert",
    inventory_has_one_channel_eq,
    inventory,
    inventory_without_channel_eq(inventory),
    "the named Studio Grand strip has a complete AX inventory containing exactly one `Channel EQ`",
    "remove or rename Channel EQ on Studio Grand: the exact-name inventory predicate refuses before "
    "the write operation receives an insert",
)
if not inventory_has_one_channel_eq(inventory):
    finish()

channel_eq = next(plugin for plugin in inventory["plugins"] if plugin.get("name") == SLOT_NAME)
insert = channel_eq["insert"]

tool, built = compile_probe()
ev.check(
    "301/precondition-the-read-only-raw-witness-built",
    built.returncode == 0,
    "the independent read-only AX witness compiled, so the zero-step wire read has an exact current "
    "raw seed rather than a fabricated dB conversion",
    f"rc={built.returncode} stderr={(built.stderr or b'').decode('utf-8', 'replace')[:300]!r}",
    "break the witness source: no value can be seeded safely for the zero-step product read",
)
if built.returncode != 0:
    finish()

raw_before = raw_probe(tool)
ev.note("301/read-only-raw-ax-before-wire-read", raw_before)
ev.falsifiable(
    "301/precondition-the-uniquely-named-channel-eq-raw-witness-read-both-gain-controls",
    raw_witness_is_complete,
    raw_before,
    raw_witness_without_peak_1_display(raw_before),
    "the unique named Channel EQ witness returned raw AXValue and AXValueDescription for Peak 1 Gain "
    "and the Peak 2 Gain negative control",
    "clear Peak 1 Gain's AXValueDescription while preserving the raw witness shape: the required "
    "rendering read is rejected before the MCP operation starts",
)
if not raw_witness_is_complete(raw_before):
    finish()

raw_peak_1_before = raw_slider(raw_before, PEAK_1_GAIN)
raw_peak_2_before = raw_slider(raw_before, PEAK_2_GAIN)
seed_raw = float(raw_peak_1_before["value"])

# This product response is the recorded before value/display. Because its raw request is the just
# observed raw AXValue, a correct increment walk returns `walk_steps: 0`; it does not nudge. The
# raw witness above exists only because no separate public parameter-read operation is registered.
wire_before = safe_set_eq(seed_raw, RAW_UNIT, track_ref, insert, project_path)
before_observation = {"seed_raw": seed_raw, "response": wire_before}
ev.note("301/before-peak-1-gain-through-product-readback", before_observation)
ev.falsifiable(
    "301/before-the-product-readback-returns-the-current-raw-value-and-display-without-a-step",
    zero_step_read_landed,
    before_observation,
    nested_witness(before_observation, "response", walk_steps=1),
    "set_eq_band_verified reads the seeded current Peak 1 Gain through its own State-A readback, "
    "with raw value and Logic's non-empty AXValueDescription recorded and no nudge accepted",
    "make the zero-step request take one nudge: the product-before predicate rejects it rather than "
    "calling a write-produced value the starting point",
)
if not zero_step_read_landed(before_observation):
    # Even a failing zero-step call can have changed the slider. Its requested value is the raw
    # witness baseline, so drive the same operation once more to restore that known value before
    # reporting the failure.
    restore_after_before_failure = safe_set_eq(seed_raw, RAW_UNIT, track_ref, insert, project_path)
    ev.note("301/restore-after-failed-before-read", restore_after_before_failure)
    ev.restored(
        "301/failed-before-read-is-returned-to-its-raw-witness-seed",
        restored_to_before({"before_raw": seed_raw, "response": restore_after_before_failure}),
        f"response={restore_after_before_failure!r}",
    )
    finish()

before_raw = float(wire_before["observed_normalized"])
before_display = wire_before["observed_display"]
target_raw = before_raw + VISIBLE_RAW_DISTANCE if before_raw <= RAW_MAX - VISIBLE_RAW_DISTANCE else before_raw - VISIBLE_RAW_DISTANCE
direction = 1.0 if target_raw > before_raw else -1.0
target_is_visible = (
    RAW_MIN <= target_raw <= RAW_MAX
    and abs(target_raw - before_raw) >= VISIBLE_RAW_DISTANCE
)
ev.check(
    "301/precondition-the-raw-write-target-is-visibly-away-from-before",
    target_is_visible,
    "the requested raw Peak 1 Gain is in 0...480 and at least 40 raw AXValue units from its read "
    "baseline, so a one-step result cannot masquerade as a landing",
    f"before_raw={before_raw!r} target_raw={target_raw!r} distance={abs(target_raw - before_raw)!r}",
    "reduce the requested distance to one: the landing assertion would no longer distinguish the "
    "known one-step AX behavior from convergence",
)
if not target_is_visible:
    finish()

# Re-scan immediately before the mutating sequence. As above, `None` alone is clear; a detector
# failure is not a permission slip to write through an unknown modal state.
modal_before_write = E.blocking_modal()
ev.check(
    "301/precondition-no-blocking-modal-immediately-before-the-write-sequence",
    modal_before_write is None,
    "the second modal scan completed clear immediately before the driver sends the mutating requests",
    f"blocking_modal={modal_before_write!r}",
    "put up a modal after preflight or make the second scan unreadable: the harness refuses before "
    "the Peak 1 walk",
)
if modal_before_write is not None:
    finish()

arrange = E.logic_window()
title_band = (0, 0, arrange["w"], 28) if arrange else None
title_subject = f"the title band of the {arrange['title']!r} document window" if arrange else None
ev.check(
    "301/precondition-a-project-window-is-available-for-the-refusal-visual",
    title_band is not None and bool(title_subject),
    "a Logic document window is visible for the final no-write visual assertion",
    f"arrange={arrange!r} title_band={title_band!r}",
    "close the document window: the final refusal cannot be captured or visually checked",
)
if title_band is None:
    finish()

recording = ev.record_screen(seconds=120)

# Both requests execute even if the first one fails. A red raw landing remains a red result, while
# the independent dB request can still reveal whether the display-target branch is reachable. The
# `finally` restoration is unconditional after these requests begin.
raw_write = {}
display_write = {}
restore = {}
try:
    raw_write = safe_set_eq(target_raw, RAW_UNIT, track_ref, insert, project_path)
    raw_write_observation = {"target_raw": target_raw, "response": raw_write}
    ev.note("301/peak-1-gain-visible-raw-write", raw_write_observation)
    ev.falsifiable(
        "301/the-visible-raw-write-lands-after-more-than-one-walk-step",
        raw_walk_landed,
        raw_write_observation,
        raw_one_step_witness(raw_write_observation, before_raw, direction),
        "State A reports the requested raw value within tolerance 0 after more than one increment-walk "
        "step; one AXValue assignment is explicitly not enough",
        "replace the walk with a single AXValue assignment: the same-shape one-step observation is "
        "rejected because it did not reach the requested raw value",
    )

    display_move_observation = {"before": wire_before, "after": raw_write}
    ev.falsifiable(
        "301/the-logic-display-moved-with-the-verified-raw-value",
        display_changed_with_raw_value,
        display_move_observation,
        raw_move_with_stale_display(display_move_observation),
        "the product's raw readback and AXValueDescription both changed; a raw move paired with the "
        "old rendering is not treated as the same control",
        "hold observed_display at the before string while preserving the moved raw value: this rejects "
        "a split raw/rendering observation",
    )

    # Pick one of the two measured-format values only from the returned rendering. This is selection
    # between literal dB requests, not a conversion from raw AXValue to dB.
    display_value = -2.2 if raw_write.get("observed_display") == "+2.2 dB" else 2.2
    wanted_display = "-2.2 dB" if display_value < 0 else "+2.2 dB"
    display_write = safe_set_eq(display_value, DISPLAY_UNIT, track_ref, insert, project_path)
    display_observation = {
        "wanted_value": display_value,
        "wanted_display": wanted_display,
        "response": display_write,
    }
    ev.note("301/peak-1-gain-display-unit-write", display_observation)
    ev.falsifiable(
        "301/a-db-request-lands-on-logics-own-rendered-string",
        display_request_landed,
        display_observation,
        # NOT `before_display`. The dB request is chosen to be the value that is NOT currently
        # rendered, but the raw write before it can leave the control showing exactly the string
        # this request asks for — and then a counterexample built from `before_display` is IDENTICAL
        # to the observation, changes nothing, and cannot be rejected. Derive the counterexample
        # from the requested rendering instead, so it always differs from what the run asked for.
        nested_witness(display_observation, "response",
                       observed_display=f"not {wanted_display}"),
        "the dB request reaches State A only when Logic reports the exact requested AXValueDescription; "
        "the harness never supplies a Hz/dB raw mapping",
        "return a different AXValueDescription for the requested dB value: a value in the declared "
        "unit without Logic's exact rendering is rejected",
    )
finally:
    restore = safe_set_eq(before_raw, RAW_UNIT, track_ref, insert, project_path)
    restore_observation = {"before_raw": before_raw, "response": restore}
    ev.note("301/restore-peak-1-gain-through-same-operation", restore_observation)
    ev.falsifiable(
        "301/restore-puts-peak-1-gain-back-at-the-recorded-before-raw-value",
        restored_to_before,
        restore_observation,
        nested_witness(restore_observation, "response", observed_normalized=before_raw + direction),
        "the same set_eq_band_verified operation reaches State A with readback equal to the recorded "
        "before raw value, rather than merely claiming rollback",
        "leave the restore response one raw step away from before: the exact readback predicate rejects "
        "the un-restored state",
    )
    ev.restored(
        "301/peak-1-gain-is-restored-by-verified-readback",
        restored_to_before(restore_observation),
        f"before_raw={before_raw!r} restore_response={restore!r}",
    )

# The final request is intentionally raw 481, just outside the measured 0...480 rail. It must fail
# at validation (`write_attempted:false`), and the post-request product readback below confirms no
# value changed while that State C was produced.
refusal_before = ev.shot("301/before-out-of-range-refusal", settle_region=title_band,
                         window_title=arrange["title"])
out_of_range = safe_set_eq(OUT_OF_RANGE_RAW, RAW_UNIT, track_ref, insert, project_path)
ev.note("301/out-of-range-raw-request", out_of_range)

# The verified operation leaves its editor window available for its next read. Re-opening that window
# with the raw witness would mistake an existing window for an Open failure, so these are deliberately
# zero-step product readbacks. If a buggy out-of-range request did move either control, the matching
# raw request walks it back to its seed but reports `walk_steps > 0`, preserving the red result.
peak_1_after_refusal = safe_set_eq(before_raw, RAW_UNIT, track_ref, insert, project_path)
peak_2_after = safe_set_eq(
    float(raw_peak_2_before["value"]), RAW_UNIT, track_ref, insert, project_path,
    band="Peak 2", parameter="Gain",
)
ev.note("301/peak-1-readback-after-refused-request", peak_1_after_refusal)
ev.note("301/peak-2-negative-control-readback-after-whole-run", peak_2_after)

refusal_observation = {
    "response": out_of_range,
    "before": {"value": before_raw, "value_description": before_display},
    "after": peak_1_after_refusal,
}
refusal_counterexample = nested_witness(refusal_observation, "response", write_attempted=True)
refusal_counterexample = nested_witness(
    refusal_counterexample,
    "after",
    observed_normalized=before_raw + direction,
    observed_display="a changed rendering",
    walk_steps=1,
)
ev.falsifiable(
    "301/an-out-of-range-raw-request-is-refused-before-any-write-and-does-not-move-peak-1",
    out_of_range_refused_without_motion,
    refusal_observation,
    refusal_counterexample,
    "raw 481 returns State C with write_attempted:false, while a zero-step product readback confirms "
    "Peak 1 raw value and Logic display remain at the recorded before state",
    "move range validation after the AX write: the same-shaped response records write_attempted:true "
    "and the post-request product read needs a step to return Peak 1 to before",
)

other_band_observation = {"before": raw_peak_2_before, "response": peak_2_after}
other_band_counterexample = nested_witness(
    other_band_observation,
    "response",
    observed_normalized=float(raw_peak_2_before["value"]) + 1.0,
    walk_steps=1,
)
ev.falsifiable(
    "301/negative-control-peak-2-gain-is-unchanged-across-the-whole-run",
    other_band_is_unchanged,
    other_band_observation,
    other_band_counterexample,
    "the other named band parameter, Peak 2 Gain, reaches a zero-step product readback with its exact "
    "before raw AXValue and AXValueDescription after every Peak 1 request; a wrong-slider walk turns "
    "this red",
    "change Peak 2 Gain by one raw step while retaining its otherwise raw response shape: the negative "
    "control rejects the wrong-slider outcome and the same request returns it to its seed",
)

refusal_after = ev.shot("301/after-out-of-range-refusal", settle_region=title_band,
                        window_title=arrange["title"])
ev.visual(
    "301/the-refused-out-of-range-request-does-not-change-the-document-title-band",
    refusal_before["file"],
    refusal_after["file"],
    title_band,
    subject=title_subject,
    expect_change=False,
    why="the final request is required to stop before any write; the title band is captured only around "
    "that refusal, after the earlier Peak 1 value has already been restored",
)

driver.close()
driver = None
ev.stop_recording(recording)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
