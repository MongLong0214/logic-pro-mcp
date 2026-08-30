#!/usr/bin/env python3
"""Live proof that startup clears a stale chord marker without clearing a live owner's marker.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_458_a_stale_chord_marker_is_cleared_on_start.py <worktree> <full-40-char-head-sha>

This run starts the release artifact three times.  The first start can post one real synthetic
key-up with ZERO flags for the deliberately stale marker.  Zero flags release no modifier and press
no key, so that event releases nothing and presses nothing on the machine running the harness.

WHAT THIS DOES NOT PROVE
------------------------
It does not observe system modifier state, verify that macOS delivered an event, or exercise the
chord path that writes the marker.  It proves only the startup-recovery half; the chord half remains
covered by unit tests alone.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


# What this harness proves, for `harness_evidence_coverage.py`.  `LogicProServer.start()` invokes
# recovery, `StuckModifierRecovery` selects/removes each marker, and `AXMouseHelper` is the production
# chord boundary that arms/disarms that same marker.  This run intentionally proves only the first two
# halves; see the module docstring for the chord-path boundary.
COVERS = [
    "Sources/LogicProMCP/Accessibility/AXMouseHelper.swift",
    "Sources/LogicProMCP/Accessibility/StuckModifierRecovery.swift",
    "Sources/LogicProMCP/Server/LogicProServer.swift",
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
checks = []


def prove(tag, predicate, observation, counterexample, expected, mutation):
    """Record an assertion that evaluates both the observation and a rejected state."""
    passed = ev.falsifiable(tag, predicate, observation, counterexample, expected, mutation)
    checks.append(passed)
    return passed


# These values were read from `StuckModifierRecovery.swift`, not remembered: its user-domain
# `applicationSupportDirectory` gets `LogicProMCP` appended, and `markerURL(for:in:)` writes
# `chord-in-flight-<pid>.json`.  `Marker` decodes these exact three JSON fields.
MARKER_DIRECTORY = Path.home() / "Library" / "Application Support" / "LogicProMCP"
MARKER_PREFIX = "chord-in-flight-"
MARKER_SUFFIX = ".json"
MARKER_KEY_CODE = 56
MARKER_FLAGS = 1 << 17

# This is deliberately read from the product policy instead of spelling this host's Korean label
# into the harness. The probe receives the entire exact-match family, so a localised run measures
# the same control-bar identity the product uses without pretending English is universal.
CONTROL_BAR_LABELS = E.label_set("controlBarGroupLabel")
CONTROL_VALUES_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "ax_control_bar_control_values.swift")
CONTROL_VALUES_TOOL = os.path.join(ev.dir, "ax_control_bar_control_values")
control_values_build = None


def control_bar_control_values():
    """Read every control-bar AXCheckBox/AXButton as `AXDescription -> AXValue`, or fail closed."""
    global control_values_build
    if not (isinstance(CONTROL_BAR_LABELS, list) and CONTROL_BAR_LABELS
            and all(isinstance(label, str) and label.strip() for label in CONTROL_BAR_LABELS)):
        return {"ok": False, "error": "AXLocalePolicy.controlBarGroupLabel could not be read"}
    if control_values_build is None:
        control_values_build = subprocess.run(
            ["swiftc", "-O", CONTROL_VALUES_SOURCE, "-o", CONTROL_VALUES_TOOL],
            capture_output=True, text=True,
        )
    if control_values_build.returncode != 0:
        return {
            "ok": False,
            "error": "the direct AX control-bar reader did not compile",
            "stderr": (control_values_build.stderr or "")[:400],
        }
    result = subprocess.run([CONTROL_VALUES_TOOL, json.dumps(CONTROL_BAR_LABELS, ensure_ascii=False)],
                            capture_output=True, text=True)
    try:
        read = json.loads(result.stdout or "{}")
    except ValueError:
        read = {"ok": False, "error": "the direct AX control-bar reader did not emit JSON",
                "raw": (result.stdout or result.stderr)[:400]}
    if not isinstance(read, dict):
        read = {"ok": False, "error": "the direct AX control-bar reader emitted a non-object"}
    read["returncode"] = result.returncode
    return read


def control_bar_values_are_unchanged(witness):
    """The map is evidence only when both complete reads name a non-empty identical control set."""
    if not isinstance(witness, dict):
        return False
    before = witness.get("before")
    after = witness.get("after")
    if not (isinstance(before, dict) and isinstance(after, dict)
            and before.get("ok") is True and after.get("ok") is True
            and before.get("returncode") == 0 and after.get("returncode") == 0):
        return False
    before_values = before.get("controls")
    after_values = after.get("controls")
    return (isinstance(before_values, dict) and isinstance(after_values, dict)
            and bool(before_values) and bool(after_values)
            and before.get("control_count") == len(before_values)
            and after.get("control_count") == len(after_values)
            and before_values == after_values)


def a_real_control_value_changed(witness):
    """Copy the raw AX observation and alter one read value, preserving the observed shape."""
    counterexample = json.loads(json.dumps(witness, ensure_ascii=False))
    after = counterexample.get("after") if isinstance(counterexample, dict) else None
    values = after.get("controls") if isinstance(after, dict) else None
    if not isinstance(values, dict) or not values:
        return counterexample
    description = next(iter(values))
    value = values[description]
    if isinstance(value, bool):
        values[description] = not value
    elif isinstance(value, (int, float)):
        values[description] = value + 1
    elif isinstance(value, str):
        values[description] = value + " (changed)"
    else:
        # The direct reader only accepts JSON scalar AXValues. This is defensive: a new scalar
        # shape must still differ in exactly one map entry rather than turn into a structural case.
        values[description] = repr(value) + " (changed)"
    return counterexample


def marker_path(pid):
    """The same filename construction as `StuckModifierRecovery.markerURL(for:in:)`."""
    return MARKER_DIRECTORY / f"{MARKER_PREFIX}{pid}{MARKER_SUFFIX}"


def marker_directory_state():
    """Only marker files are in scope; unrelated Application Support files are never touched."""
    try:
        entries = list(MARKER_DIRECTORY.iterdir())
    except FileNotFoundError:
        return {"readable": True, "directory_exists": False, "marker_files": []}
    except OSError as exc:
        return {"readable": False, "directory_exists": MARKER_DIRECTORY.exists(),
                "marker_files": None, "error": repr(exc)}

    return {
        "readable": True,
        "directory_exists": True,
        "marker_files": sorted(
            entry.name for entry in entries
            if entry.is_file() and entry.name.startswith(MARKER_PREFIX)
            and entry.name.endswith(MARKER_SUFFIX)
        ),
    }


def process_is_alive(pid):
    """The `kill(pid, 0)` decision used by production, including its fail-safe error cases."""
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def marker_data(pid):
    """JSONDecoder accepts the `Marker` fields read from the Swift source above."""
    return json.dumps({"keyCode": MARKER_KEY_CODE, "flags": MARKER_FLAGS, "pid": pid},
                      separators=(",", ":")).encode("utf-8")


planted = {}


def plant(path, data):
    """Create one harness-owned production-shaped marker without overwriting any existing file."""
    MARKER_DIRECTORY.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as fh:
        fh.write(data)
    stat = path.stat()
    planted[path] = {
        "device": stat.st_dev,
        "inode": stat.st_ino,
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    return path


def remove_ours(path):
    """Remove only an unchanged inode and payload this harness created; never unlink a replacement."""
    proof = planted.get(path)
    if proof is None:
        return {"path": str(path), "removed": False, "why": "not planted by this harness"}
    if not path.exists():
        return {"path": str(path), "removed": True, "why": "already removed by the artifact"}
    try:
        stat = path.stat()
        data = path.read_bytes()
    except OSError as exc:
        return {"path": str(path), "removed": False, "why": f"cannot re-read: {exc!r}"}
    unchanged = (stat.st_dev == proof["device"] and stat.st_ino == proof["inode"]
                 and hashlib.sha256(data).hexdigest() == proof["sha256"])
    if not unchanged:
        return {"path": str(path), "removed": False,
                "why": "file changed or was replaced after the harness planted it"}
    try:
        path.unlink()
    except OSError as exc:
        return {"path": str(path), "removed": False, "why": repr(exc)}
    return {"path": str(path), "removed": not path.exists(), "why": "harness-owned marker"}


def start_release_artifact(marker):
    """Start the release binary, then make a read-only call that records the live artifact drive."""
    driver = E.Driver()
    try:
        health = driver.tool("logic_system", "health", {})
        posted_clear, info_channel_live = driver.server_logged("posted a modifier-clear event")
        return {
            "server_pid": driver.proc.pid,
            "health_responded": isinstance(health, dict) and "_transport_error" not in health,
            "marker_exists_after_start": marker.exists(),
            "posted_modifier_clear": posted_clear,
            "info_log_channel_live": info_channel_live,
        }
    finally:
        driver.close()


def finish():
    summary = ev.write()
    print(json.dumps(summary, indent=1))
    return 0 if E.is_clean(summary) else 1


# A pre-existing marker could be a real interrupted chord.  Refuse instead of deleting it: every
# subsequent deletion is guarded by `planted`, but this check is what keeps the run from even trying
# to share a recovery directory with somebody else's state.
# `blocking_modal` has THREE answers, and an earlier draft of this harness read them as two.
# `None` means a completed scan found nothing — that is the clean case. A dict describes a detected
# blocker. `E.MODAL_CANNOT_TELL` means the scan could not be completed, which is not a clean screen
# and must refuse just as loudly as a found modal: a run measured through a blocker it could not
# see is the failure this whole precondition exists to stop.
modal_before = E.blocking_modal()
no_modal = prove(
    "458/precondition-no-blocking-modal",
    lambda observed: observed is None,
    modal_before,
    {"kind": "modal_panel", "layer": 8, "w": 268, "h": 283},
    "the modal scan completed and found no blocking panel or sheet before this run starts the "
    "artifact; a cannot-tell answer refuses here too",
    "leave a modal dialog or sheet open, or break the scan so it answers cannot_tell: this "
    "precondition turns red rather than treating a blocked run as modifier recovery",
)
initial_state = marker_directory_state()
empty_marker_directory = prove(
    "458/precondition-no-marker-files-already-exist",
    lambda observed: observed.get("readable") is True and observed.get("marker_files") == [],
    initial_state,
    {"readable": True, "directory_exists": True,
     "marker_files": [f"{MARKER_PREFIX}someone-else{MARKER_SUFFIX}"]},
    "the production marker directory is readable and has no production-shaped marker files",
    "leave a marker from another run in the directory: this run refuses instead of removing it",
)
ev.note("458/initial-marker-directory-state", initial_state)
if not (no_modal and empty_marker_directory):
    sys.exit(finish())

# The two captures and recording remain useful context: they show whether the control bar was idle
# before this run.  They are not the recovery side-effect witness. Measured on the settled 10,24,
# 1900,58 region, three idle captures were byte-identical, yet before/after recovery differed in
# exactly 12 Retina columns (six points), window x=1065...1070, at the right edge of the LCD's
# `박자표` / `조표` AXPopUpButton (frame 1012,63 63x23). That is a real chevron/focus-ring redraw,
# but pixels cannot distinguish it from a pressed key, so the AX map below is the control for this
# question. Do not reinstate a recovery `ev.visual(...)` comparison over this band.
arrange_window = E.logic_window()
window_ready = prove(
    "458/precondition-an-arrange-window-is-visible-for-the-recording",
    lambda observed: isinstance(observed, dict) and bool(observed.get("title")),
    arrange_window,
    None,
    "a visible Logic arrange window can supply the recorded visual control",
    "close the arrange window: the recording has no defined subject and this precondition turns red",
)
if not window_ready:
    sys.exit(finish())

band, band_subject = ev.located_band("Control Bar", "--min-width", "1000")
band_ready = prove(
    "458/precondition-the-control-bar-is-unambiguous",
    lambda observed: isinstance(observed, dict) and observed.get("band") is not None
    and isinstance(observed.get("subject"), str) and bool(observed["subject"].strip()),
    {"band": band, "subject": band_subject},
    {"band": None, "subject": None},
    "an unambiguous Control Bar region, named by the UI, can be used for the visual control",
    "make the Control Bar lookup ambiguous or unreadable: no anonymous rectangle is substituted",
)
if not band_ready:
    sys.exit(finish())

quiet_before = ev.shot("458/quiet-control-bar-before", settle_region=band,
                       window_title=arrange_window["title"])
time.sleep(1)
quiet_after = ev.shot("458/quiet-control-bar-after", settle_region=band,
                      window_title=arrange_window["title"])
quiet = {
    "first_settled": quiet_before.get("settled"),
    "second_settled": quiet_after.get("settled"),
    "first_hash": quiet_before.get("region_hash"),
    "second_hash": quiet_after.get("region_hash"),
}
quiet_control = prove(
    "458/precondition-the-visual-control-is-quiet",
    lambda observed: (observed.get("first_settled") is True and observed.get("second_settled") is True
                      and observed.get("first_hash") is not None
                      and observed.get("first_hash") == observed.get("second_hash")),
    quiet,
    {"first_settled": True, "second_settled": True, "first_hash": "before", "second_hash": "after"},
    "two idle captures of the Control Bar are identical, so the recording starts from a quiescent UI",
    "start transport playback: the transport readout genuinely moves and this idle precondition turns red",
)
# Evidence requires one visual assertion. This one is deliberately only the idle precondition: the
# transport readout would genuinely move under playback, and it says nothing about startup recovery.
quiet_visual = ev.visual(
    "458/precondition-the-control-bar-is-visually-quiet-before-recovery",
    quiet_before["file"], quiet_after["file"], band, expect_change=False, subject=band_subject,
    why="the transport readout would move during playback; this establishes only that the retained "
        "recording context is idle before the artifact starts",
)
if not (quiet_control and quiet_visual):
    sys.exit(finish())

recording = ev.record_screen(seconds=45)
visual_before = ev.shot("458/before-startup-recovery", settle_region=band,
                        window_title=arrange_window["title"])
cleanup = []

try:
    # An invented PID is unsound: it may name a live, unrelated process.  `/usr/bin/true` gives this
    # run an honest PID, and waiting for it plus the same `kill(pid, 0)` probe production uses establishes
    # that it is gone before its marker is planted.
    child = subprocess.Popen(["/usr/bin/true"])
    dead_pid = child.pid
    child.wait()
    dead_owner = {"pid": dead_pid, "is_alive_after_wait": process_is_alive(dead_pid)}
    dead_owner_is_gone = prove(
        "458/precondition-the-dead-marker-owner-is-really-dead",
        lambda observed: isinstance(observed.get("pid"), int) and observed["pid"] > 0
        and observed.get("is_alive_after_wait") is False,
        dead_owner,
        {"pid": dead_pid, "is_alive_after_wait": True},
        "a PID supplied by a waited-for `/usr/bin/true` child now has no live process",
        "reuse a live PID: the run refuses rather than asking recovery to clear a live owner's marker",
    )
    if not dead_owner_is_gone:
        raise RuntimeError("the waited-for child PID was live again before its marker could be planted")

    dead_marker = plant(marker_path(dead_pid), marker_data(dead_pid))
    control_values_before = control_bar_control_values()
    ev.note("458/control-bar-AXValues-before-startup-recovery", control_values_before)
    dead_result = start_release_artifact(dead_marker)
    dead_result.update(dead_owner)
    control_values_after = control_bar_control_values()
    ev.note("458/control-bar-AXValues-after-startup-recovery", control_values_after)
    prove(
        "458/a-marker-owned-by-a-dead-pid-is-cleared-on-artifact-start",
        lambda observed: (observed.get("health_responded") is True
                          and observed.get("is_alive_after_wait") is False
                          and observed.get("marker_exists_after_start") is False),
        dead_result,
        {"health_responded": True, "is_alive_after_wait": False,
         "marker_exists_after_start": True},
        "the release artifact removes a parseable marker whose different owner is no longer live",
        "remove `StuckModifierRecovery.recoverIfNeeded()` from `LogicProServer.start()`: the marker "
        "remains after startup",
    )
    control_value_observation = {"before": control_values_before, "after": control_values_after}
    # This is a raw observation plus a same-shaped counterexample, as in #290: only one real
    # AXValue is changed. The predicate therefore rejects a transport press because that map entry
    # moved, not because a required field was removed or the reader was made structurally invalid.
    prove(
        "458/the-zero-flags-recovery-does-not-change-control-bar-controls",
        control_bar_values_are_unchanged,
        control_value_observation,
        a_real_control_value_changed(control_value_observation),
        "the recovery's only possible input is a zero-flags key-up; a key that pressed any transport "
        "button or checkbox would change its AXDescription-to-AXValue map, which is identical before "
        "and after the startup recovery",
        "post a key-down or non-zero-flags event from recovery: a transport control's AXValue changes "
        "and this map comparison turns red",
    )
    # Keep each case independent even on a broken binary.  This removes only the unchanged marker
    # `plant` recorded above; a replacement is left in place and makes restoration fail loudly.
    cleanup.append(remove_ours(dead_marker))

    live_pid = os.getpid()
    live_marker = plant(marker_path(live_pid), marker_data(live_pid))
    live_result = start_release_artifact(live_marker)
    live_result.update({"marker_pid": live_pid, "owner_is_harness": live_pid == os.getpid(),
                        "owner_is_alive": process_is_alive(live_pid)})
    prove(
        "458/a-marker-owned-by-a-live-pid-survives-artifact-start",
        lambda observed: (observed.get("health_responded") is True
                          and observed.get("owner_is_harness") is True
                          and observed.get("owner_is_alive") is True
                          and observed.get("marker_exists_after_start") is True),
        live_result,
        {"health_responded": True, "owner_is_harness": True, "owner_is_alive": True,
         "marker_exists_after_start": False},
        "the release artifact keeps the marker belonging to this live Python harness process",
        "delete every marker at startup instead of consulting `shouldRecover`: this marker is gone",
    )

    # Reuse the now-available dead filename so this is exactly `markerURL(for:in:)`'s PID shape,
    # while its bytes make `JSONDecoder().decode(Marker.self, from:)` fail.
    garbage_marker = plant(marker_path(dead_pid), b"not JSON")
    garbage_result = start_release_artifact(garbage_marker)
    prove(
        "458/an-undecodable-production-shaped-marker-is-discarded-and-posts-nothing",
        lambda observed: (observed.get("health_responded") is True
                          and observed.get("marker_exists_after_start") is False
                          and observed.get("posted_modifier_clear") is False
                          and observed.get("info_log_channel_live") is True),
        garbage_result,
        {"health_responded": True, "marker_exists_after_start": False,
         "posted_modifier_clear": True, "info_log_channel_live": True},
        "the release artifact removes undecodable marker bytes and records no modifier-clear post",
        "skip the decode-failure removal or attempt recovery before decoding: the marker survives or "
        "the release artifact logs a modifier-clear post",
    )
except Exception as exc:  # noqa: BLE001 - cleanup and the evidence receipt must still happen
    prove(
        "458/the-harness-reached-all-startup-recovery-observations",
        lambda observed: observed.get("error") is None,
        {"error": repr(exc)},
        {"error": "a deliberately non-empty error"},
        "all three release-artifact startups complete without a harness error",
        "break a marker setup or artifact startup: the exception is recorded as a failed observation",
    )
finally:
    for path in list(planted):
        cleanup.append(remove_ours(path))
    # If this run had to create an otherwise absent directory, removing its final empty directory
    # returns the whole directory state to the precondition.  `rmdir` cannot remove unrelated files.
    if not initial_state.get("directory_exists"):
        try:
            MARKER_DIRECTORY.rmdir()
        except OSError:
            pass

    restored_state = marker_directory_state()
    ev.note("458/marker-cleanup", cleanup)
    restored = prove(
        "458/restore-the-marker-directory-is-back-to-its-precondition-state",
        lambda observed: observed == initial_state,
        restored_state,
        {**initial_state, "marker_files": [f"{MARKER_PREFIX}left-behind{MARKER_SUFFIX}"]},
        "the marker directory state now exactly matches the no-marker state observed before the run",
        "leave a harness marker behind: the recorded directory state differs and this restore check turns red",
    )
    ev.restored("458/remove-only-harness-owned-markers", restored,
                f"initial={initial_state!r} restored={restored_state!r} cleanup={cleanup!r}")

    # Keep the pre/post captures in the evidence bundle, but intentionally do not compare them with
    # `ev.visual`: the measured six-point LCD chevron/focus redraw is a real pixel difference that
    # cannot answer whether recovery pressed a control. The AXValue map above is that control.
    ev.shot("458/after-startup-recovery", settle_region=band,
            window_title=arrange_window["title"])
    ev.stop_recording(recording)

sys.exit(finish())
