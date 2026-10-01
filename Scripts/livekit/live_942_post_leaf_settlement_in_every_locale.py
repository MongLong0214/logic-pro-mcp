#!/usr/bin/env python3
"""Live proof that the post-leaf settlement acts on Logic's own screen (#942).

Usage: LPM_LIVE_LOCK=<held lock> LPM_EVIDENCE_ROOT=<absolute dir> /usr/bin/python3 \
       Scripts/livekit/live_942_post_leaf_settlement_in_every_locale.py \
       <worktree> <full-40-char-head> <candidate-binary> <control-binary> [--lprojs lproj ...]
       (default lprojs: en ko ja de es fr it pt zh_CN zh_TW; both binaries debug builds)

WHAT IS ASKED
-------------
Fourteen `goto_position` results end with the script not having observed Logic's menu, and each is
followed by one reading of the window server's list and at most the Escapes that reading permits
(`settlePostLeafScreen`). The unit tests drive that settlement over scripted lists. This asks whether
it does the same on Logic: whether its reading names what is really on screen, whether the Escapes it
sends close what it says they close, and whether it sends nothing at a window it cannot name.

HOW THE SCREEN IS PUT INTO EACH STATE
-------------------------------------
None of the fourteen can be produced on demand from Logic: each needs the script to fail at one point
after the leaf click. So both binaries are debug builds started with LOGIC_MCP_942_POST_LEAF_HOLD_DIR,
the seam in `AccessibilityChannel+GotoPostLeafLiveHold.swift`, which replaces the script and nothing
else. The route still takes its frontmost gate and its cross-process lock and reads its baseline
before the seam holds; after the release it parses the result, settles and replies as it does in a
release build. Per hold the harness writes one of the fourteen names to `result`, calls
`logic_transport goto_position` on a thread, waits for the server to write `entered`, arranges the
screen through System Events, and writes `release`.

The fourteen names are read from the sources (the twelve `PostLeafCleanupSite` identifiers and the
seam's two appearance names) and rotate across holds, so every name is released under more than one
screen and in more than one language.

Per language, on a fresh launch of the locale-campaign fixture, the candidate is held five times:
  nothing          nothing arranged: the settlement must read nothing and send nothing.
  menu             the Navigate menu opened: one Escape at the menu, the menu gone.
  dialog           Go To Position opened: one Escape at the dialog, which the reading must name by the
                   title the window server gave the server process, the dialog gone.
  menu_over_dialog the dialog, then the menu over it: an Escape at the menu, then one at the dialog,
                   both gone.
  unidentified     the Step Input Keyboard window opened, then the menu: a window the server did not
                   open and cannot name. It must refuse with `unidentified_dialog_present` and send
                   nothing, so the menu is still open after the reply.
The control is the same debug build with the settlement block removed from the route. It is held for
menu, dialog and menu_over_dialog and must leave each surface up and carry no settlement object.

Every reading of the screen the harness makes is its own: Logic-owned windows from
CGWindowListCopyWindowInfo, taken after the reply and again 1.5 s later. A menu is a Logic window at
or above the pop-up menu level; the dialog is a Logic window that was not listed before the hold and
whose name is a measured Go To Position title in docs/locale/ui-labels.json. Clean-up (Escapes, and
the Window menu item that closes the Step Input Keyboard) is outside the measured bracket and is
verified by a re-read before the next hold.

PASS
----
In every language every candidate hold and every control hold matches its row above, each checked
against the other binary's reading of the same screen (or, for nothing and unidentified, the
candidate's own menu hold) as the state it must reject. Korean is restored at the end and read back.
The exit code is also the evidence document's own `is_clean`.

WHAT IS NOT JUDGED
------------------
The script. Its result is substituted, so nothing here shows that any of the fourteen results is
reached on Logic or that the screen a real failure leaves looks like one arranged here; what is shown
is what the route does with each of them over the screens that were arranged. One menu (Navigate),
one unidentified window (Step Input Keyboard), one fixture, one Logic installation.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402
import probe_942_escape_over_goto_dialog as P  # noqa: E402

HOLD_KEY = "LOGIC_MCP_942_POST_LEAF_HOLD_DIR"
ENTER_WAIT = 20.0
REPLY_WAIT = 90.0
ARRANGE_WAIT = 4.0
SURVIVAL_SECONDS = 1.5
EDGE_POINTS = 16
BAR = 9
CANDIDATE_HOLDS = ("nothing", "menu", "dialog", "menu_over_dialog", "unidentified")
CONTROL_HOLDS = ("menu", "dialog", "menu_over_dialog")
RECORDING_SECONDS_PER_LANGUAGE = 200


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("candidate")
    parser.add_argument("control")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS), metavar="lproj")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    for path in (args.candidate, args.control):
        if not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
    unknown = [name for name in args.lprojs if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    lock = os.environ.get("LPM_LIVE_LOCK") or ""
    if not os.path.isfile(lock):
        parser.error(f"LPM_LIVE_LOCK must name an existing lock file held by the caller (got {lock!r})")
    return args


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def hold_names(worktree):
    """The fourteen names the seam answers to, read from the sources it reads them from."""
    channels = os.path.join(worktree, "Sources", "LogicProMCP", "Channels")
    with open(os.path.join(channels, "AccessibilityChannel+Transport.swift"), encoding="utf-8") as h:
        sites = re.findall(r'identifier: "([a-z_]+)", resultPrefix: "', h.read())
    with open(os.path.join(channels, "AccessibilityChannel+GotoPostLeafLiveHold.swift"), encoding="utf-8") as h:
        appearances = dict(re.findall(r'"(dialog_[a-z_]+)": "(DIALOG_[A-Z_]+)"', h.read()))
    return sites, appearances


def expected_result(worktree, name, appearances):
    """The script result the seam answers for a name: a site's OPEN dialog refusal or the appearance
    result, rebuilt here from the sources so the harness does not take the seam's word for it."""
    if name in appearances:
        return appearances[name]
    channels = os.path.join(worktree, "Sources", "LogicProMCP", "Channels")
    with open(os.path.join(channels, "AccessibilityChannel+Transport.swift"), encoding="utf-8") as h:
        source = h.read()
    prefix = re.search(rf'identifier: "{name}", resultPrefix: "([^"]+)"', source).group(1)
    marker = re.search(r'static let notObservedMarker = "([^"]+)"', source).group(1)
    return f"{prefix}: dialog {marker} (OPEN)"


def keyboard_item():
    """The Window menu and its Step Input Keyboard item, by the names this Logic shows."""
    bar = P.osa('tell application "System Events" to tell process "Logic Pro" to '
                'get name of every menu bar item of menu bar 1')
    if bar is None:
        return None
    shown = [item.strip() for item in bar.split(",")]
    window = next((n for n in P.names("windowMenuBar") if n in shown), None)
    if window is None:
        return None
    items = P.osa('tell application "System Events" to tell process "Logic Pro" to get name of every '
                  f'menu item of menu 1 of menu bar item {P.applescript_string(window)} of menu bar 1')
    if items is None:
        return None
    shown = [item.strip() for item in items.split(",")]
    item = next((n for n in P.names("showStepInputKeyboardMenuItem") if n in shown), None)
    return None if item is None else {"window": window, "item": item}


def toggle_keyboard(kb):
    return P.osa('with timeout of 4 seconds\ntell application "System Events" to tell process "Logic Pro" '
                 f'to click menu item {P.applescript_string(kb["item"])} of menu 1 of menu bar item '
                 f'{P.applescript_string(kb["window"])} of menu bar 1\nend timeout', timeout=8)


class Titles:
    dialog = P.names("goToPositionDialogTitle")
    keyboard = P.names("stepInputKeyboardWindowTitle")


def keyboard_window(name):
    """Whether a window name is the Step Input Keyboard's, read as the product reads it: the title
    is contained, without regard to case (`stepInputKeyboardWindowTitle`, mode `.contains`). Logic
    titles the window `<project> - <title>`; the ko pilot's whole-name comparison never saw it."""
    lowered = (name or "").lower()
    return any(title.lower() in lowered for title in Titles.keyboard)


def classify(windows, baseline_ids, level, keyboard_owner):
    """One reading of a window list against the baseline, by the server's rules: the menus are the
    Logic windows at the menu level exactly, an appeared window is any other Logic window not in
    the baseline, the dialog is named exactly and the keyboard window by containment."""
    if windows is None:
        return None
    new = P.appeared(windows, baseline_ids, level)
    return {"menus": len(P.menus(windows, level)),
            "dialogs": [w for w in new if w["name"] in Titles.dialog],
            "keyboard_windows": [w for w in new if keyboard_window(w["name"])],
            "new_windows": new,
            "keyboard_owner_is_logic": keyboard_owner}


def surfaces(baseline_ids):
    """What is on screen against the Logic windows listed before the hold; None when unread."""
    windows = P.logic_windows()
    if windows is None:
        return None
    return classify(windows, baseline_ids, P.menu_level(), P.keyboard_owner_is_logic())


def wait_surfaces(baseline_ids, predicate, seconds=ARRANGE_WAIT):
    started = time.monotonic()
    while True:
        reading = surfaces(baseline_ids)
        if reading is not None and predicate(reading):
            return reading
        if time.monotonic() - started >= seconds:
            return reading
        time.sleep(0.05)


def arrange(kind, path, kb, baseline_ids):
    """Put the screen into one hold's state; the menu clicks are left running (an open menu holds
    the AppleEvent) and handed back to be reaped after the reply."""
    menu_clicks = []
    if kind in ("dialog", "menu_over_dialog"):
        P.open_dialog(path)
        wait_surfaces(baseline_ids, lambda r: len(r["dialogs"]) == 1)
    if kind == "unidentified":
        toggle_keyboard(kb)
        wait_surfaces(baseline_ids, lambda r: len(r["keyboard_windows"]) == 1)
    if kind in ("menu", "menu_over_dialog", "unidentified"):
        menu_clicks.append(P.open_menu(path))
        wait_surfaces(baseline_ids, lambda r: r["menus"] > 0)
    return surfaces(baseline_ids), menu_clicks


def hold(driver, folder, name, kind, path, kb):
    """One held `goto_position` call, the screen arranged while it is held, and the readings after."""
    for file in ("entered", "release"):
        try:
            os.remove(os.path.join(folder, file))
        except FileNotFoundError:
            pass
    with open(os.path.join(folder, "result"), "w", encoding="utf-8") as h:
        h.write(name)
    before = P.logic_windows()
    result = {"name": name, "kind": kind, "before": before}
    if before is None:
        result["error"] = "the window list was not read before the hold"
        return result
    owner = P.keyboard_owner_is_logic()
    if owner is not True:
        # Measured 2026-10-02: a permission prompt held the keyboard over Logic, and every Escape
        # aimed at Logic's dialog went to the prompt. Nothing is arranged or sent then.
        result["error"] = f"the keyboard is not Logic's before the hold (read {owner!r})"
        return result
    baseline_ids = {w["id"] for w in before}
    box = {}

    def call():
        started = time.monotonic()
        box["reply"] = driver.tool("logic_transport", "goto_position", {"bar": BAR})
        box["seconds"] = round(time.monotonic() - started, 3)

    thread = threading.Thread(target=call, daemon=True)
    thread.start()
    entered_path = os.path.join(folder, "entered")
    started = time.monotonic()
    while not os.path.exists(entered_path) and time.monotonic() - started < ENTER_WAIT and thread.is_alive():
        time.sleep(0.05)
    try:
        with open(entered_path, encoding="utf-8") as h:
            result["entered"] = h.read()
    except OSError:
        result["entered"] = None
    menu_clicks = []
    if result["entered"] is not None:
        result["arranged"], menu_clicks = arrange(kind, path, kb, baseline_ids)
        with open(os.path.join(folder, "release"), "w", encoding="utf-8"):
            pass
    thread.join(REPLY_WAIT)
    result["reply_returned"] = not thread.is_alive()
    result["reply"] = box.get("reply")
    result["reply_seconds"] = box.get("seconds")
    result["after_reply"] = surfaces(baseline_ids)
    time.sleep(SURVIVAL_SECONDS)
    result["after_survival"] = surfaces(baseline_ids)
    result["release_left"] = os.path.exists(os.path.join(folder, "release"))
    for click in menu_clicks:
        try:
            click.wait(timeout=5)
        except subprocess.TimeoutExpired:
            click.kill()
    result["baseline_ids"] = sorted(baseline_ids)
    return result


def clean_up(result, kb):
    """Escapes until no menu and no dialog, then the Step Input Keyboard closed; re-read."""
    baseline_ids = set(result.get("baseline_ids") or [])
    for _ in range(4):
        reading = surfaces(baseline_ids)
        if reading is not None and reading["menus"] == 0 and not reading["dialogs"]:
            break
        if reading is None or reading["keyboard_owner_is_logic"] is not True:
            break  # an Escape goes to whatever holds the keyboard, and that is not Logic
        P.post_escape()
        time.sleep(0.6)
    reading = surfaces(baseline_ids)
    if reading is not None and reading["keyboard_windows"]:
        closing = {w["id"] for w in reading["keyboard_windows"]}
        toggle_keyboard(kb)
        # The window leaves by its id, not its name: after the toggle Logic keeps the same id on
        # screen, unnamed and shrinking, for about 1.3 s (measured 2026-10-02 in Korean), and a
        # wait on the name ended at once and read that closing window as one left behind.
        reading = wait_surfaces(baseline_ids,
                                lambda r: not closing & {w["id"] for w in r["new_windows"]})
    clean = (reading is not None and reading["menus"] == 0 and not reading["new_windows"])
    return {"reading": reading, "clean": clean}


def inner_region(w, h):
    """The dialog inside its rounded edge, in window points: the edge is blended with what Logic
    draws behind it (#1077's measurement of a Logic dialog), so it is not compared."""
    return (EDGE_POINTS, EDGE_POINTS, max(0, w - 2 * EDGE_POINTS), max(0, h - 2 * EDGE_POINTS))


def capture(ev, tag, window):
    bounds = window.get("bounds") or {}
    w, h = bounds.get("Width", 0), bounds.get("Height", 0)
    return ev.shot(tag, settle_region=inner_region(w, h),
                   window={"id": window["id"], "title": window.get("name") or "",
                           "x": bounds.get("X", 0), "y": bounds.get("Y", 0), "w": w, "h": h})


def run_binary(ev, role, binary, kinds, names, rotation, path, kb, worktree, appearances, tag):
    """One server, held once per kind. The control's dialog is photographed after the reply and
    1.5 s later, to be compared."""
    folder = tempfile.mkdtemp(prefix=f"lpm942-{role}-")
    os.environ[HOLD_KEY] = folder
    phases, driver = {}, None
    try:
        driver = E.Driver(binary=binary)
        for kind in kinds:
            name = names[next(rotation) % len(names)]
            phase = hold(driver, folder, name, kind, path, kb)
            phase["expected_result"] = expected_result(worktree, name, appearances)
            phase["appearance"] = name in appearances
            if role == "control" and kind == "dialog" and (phase.get("after_reply") or {}).get("dialogs"):
                window = phase["after_reply"]["dialogs"][0]
                first = capture(ev, f"{tag}/{role}/dialog-after-reply", window)
                later = P.logic_windows() or []
                if any(w["id"] == window["id"] for w in later):
                    second = capture(ev, f"{tag}/{role}/dialog-after-survival", window)
                    size = (first["window"]["w"], first["window"]["h"])
                    ev.visual(f"{tag}/{role}/dialog-unchanged", first["file"], second["file"],
                              inner_region(*size), expect_change=False,
                              why="the control sends no Escape after the reply, so the Go To Position "
                                  "dialog the harness opened during the hold stays as it was",
                              subject="the Logic window the window server listed with a measured Go To "
                                      "Position title after the control binary's reply",
                              window_points=size)
            phase["clean_up"] = clean_up(phase, kb)
            phases[kind] = phase
            print(json.dumps({"tag": tag, "role": role, "kind": kind, "name": name,
                              "entered": phase.get("entered") == phase["expected_result"],
                              "settlement": ((phase.get("reply") or {}).get("post_leaf_settlement") or {})
                              .get("action"),
                              "after": phase.get("after_reply") and {
                                  "menus": phase["after_reply"]["menus"],
                                  "dialogs": len(phase["after_reply"]["dialogs"]),
                                  "keyboard": len(phase["after_reply"]["keyboard_windows"])},
                              "clean": phase["clean_up"]["clean"]}, ensure_ascii=False), flush=True)
            if not phase.get("reply_returned"):
                # The call is still on the driver's connection; the next hold would read its reply.
                phases["error"] = f"the {kind} hold did not reply within {REPLY_WAIT:g} s"
                break
            if not phase["clean_up"]["clean"]:
                phases["error"] = f"the screen was not clean after the {kind} hold"
                break
    finally:
        if driver is not None:
            driver.close()
        os.environ.pop(HOLD_KEY, None)
        # A process named LogicProMCP whose command line names this binary: the name alone would
        # take another checkout's server, the command line alone any process that mentions the path.
        named = subprocess.run(["/usr/bin/pgrep", "-x", "LogicProMCP"], capture_output=True, text=True)
        stray = subprocess.run(["/usr/bin/pgrep", "-f", binary], capture_output=True, text=True)
        phases["server_pids_after_close"] = sorted(set(named.stdout.split()) & set(stray.stdout.split()))
        for pid in phases["server_pids_after_close"]:
            subprocess.run(["/bin/kill", "-9", pid], capture_output=True)
    return phases


# --- what each hold must show -------------------------------------------------------------------

def settlement(phase):
    reply = (phase or {}).get("reply")
    return (reply or {}).get("post_leaf_settlement") if isinstance(reply, dict) else None


def reached_the_seam(phase):
    """The server wrote the result it answered, the reply came back, the release was consumed, and
    the refusal outside the settlement is the one the name stands for."""
    phase = phase or {}
    reply = phase.get("reply") if isinstance(phase.get("reply"), dict) else {}
    outcome = reply.get("dialog_route_outcome") or ""
    outcome_ok = (outcome == phase.get("name") if phase.get("appearance") is True
                  else phase.get("appearance") is False and outcome.endswith("_cleanup_closed_false"))
    return (phase.get("entered") is not None and phase.get("entered") == phase.get("expected_result")
            and phase.get("reply_returned") is True and phase.get("release_left") is False
            and reply.get("fallback_unsafe") is True and reply.get("safe_to_retry") is False
            and outcome_ok)


def reading_of(receipt, key):
    reading = (receipt or {}).get(key) or {}
    return reading.get("menu"), reading.get("dialog"), reading.get("keyboard_owner")


def both_readings(phase, predicate):
    return all(r is not None and predicate(r) for r in ((phase or {}).get("after_reply"),
                                                        (phase or {}).get("after_survival")))


def candidate_nothing(phase):
    s = settlement(phase) or {}
    arranged = (phase or {}).get("arranged") or {}
    return (reached_the_seam(phase) and arranged.get("menus") == 0 and arranged.get("new_windows") == []
            and reading_of(s, "read") == ("closed", "absent", "logic")
            and s.get("action") == "none" and s.get("escapes_sent") == 0 and s.get("settled") is True
            and both_readings(phase, lambda r: r["menus"] == 0 and r["new_windows"] == []))


def candidate_menu(phase):
    s = settlement(phase) or {}
    arranged = (phase or {}).get("arranged") or {}
    return (reached_the_seam(phase) and arranged.get("menus", 0) > 0 and arranged.get("new_windows") == []
            and reading_of(s, "read") == ("open", "absent", "logic")
            and s.get("action") == "menu_escape_loop" and s.get("escape_targets") == ["menu"]
            and s.get("settled") is True and reading_of(s, "after") == ("closed", "absent", "logic")
            and both_readings(phase, lambda r: r["menus"] == 0 and r["new_windows"] == []))


def named_our_dialog(receipt):
    appeared = ((receipt or {}).get("read") or {}).get("appeared_windows")
    return (isinstance(appeared, list) and len(appeared) == 1
            and appeared[0].get("name") in Titles.dialog)


def candidate_dialog(phase):
    s = settlement(phase) or {}
    arranged = (phase or {}).get("arranged") or {}
    return (reached_the_seam(phase) and arranged.get("menus") == 0 and len(arranged.get("dialogs") or []) == 1
            and reading_of(s, "read") == ("closed", "identified_ours", "logic") and named_our_dialog(s)
            and s.get("action") == "dialog_cancel" and s.get("escape_targets") == ["dialog"]
            and s.get("settled") is True and reading_of(s, "after") == ("closed", "absent", "logic")
            and both_readings(phase, lambda r: r["menus"] == 0 and r["new_windows"] == []))


def candidate_menu_over_dialog(phase):
    s = settlement(phase) or {}
    arranged = (phase or {}).get("arranged") or {}
    return (reached_the_seam(phase) and arranged.get("menus", 0) > 0
            and len(arranged.get("dialogs") or []) == 1
            and reading_of(s, "read") == ("open", "identified_ours", "logic") and named_our_dialog(s)
            and s.get("action") == "menu_escape_loop" and s.get("escape_targets") == ["menu", "dialog"]
            and s.get("settled") is True and reading_of(s, "after") == ("closed", "absent", "logic")
            and both_readings(phase, lambda r: r["menus"] == 0 and r["new_windows"] == []))


def candidate_unidentified(phase):
    s = settlement(phase) or {}
    arranged = (phase or {}).get("arranged") or {}
    return (reached_the_seam(phase) and arranged.get("menus", 0) > 0
            and len(arranged.get("keyboard_windows") or []) == 1 and not arranged.get("dialogs")
            and reading_of(s, "read")[:2] == ("open", "unidentified")
            and s.get("action") == "refuse_to_act" and s.get("refusal_reason") == "unidentified_dialog_present"
            and s.get("escapes_sent") == 0 and s.get("settled") is False
            and both_readings(phase, lambda r: r["menus"] > 0 and len(r["keyboard_windows"]) == 1))


def control_left(kind):
    """The control carries no settlement and leaves what was arranged up at both readings."""
    def left(r):
        menus = r["menus"] > 0
        dialog = len(r["dialogs"]) == 1
        return {"menu": menus and not dialog, "dialog": dialog and not menus,
                "menu_over_dialog": menus and dialog}[kind]

    def predicate(phase):
        return (reached_the_seam(phase) and settlement(phase) is None
                and left((phase or {}).get("arranged") or {"menus": 0, "dialogs": []})
                and both_readings(phase, left))
    return predicate


CANDIDATE_PREDICATES = {
    "nothing": (candidate_nothing, "the reading names a closed menu, no appeared window and Logic's "
                                   "keyboard; nothing is sent and nothing is on screen after the reply"),
    "menu": (candidate_menu, "the reading names the open menu; one Escape at the menu; the menu is gone "
                             "after the reply and 1.5 s later"),
    "dialog": (candidate_dialog, "the reading names our dialog by the title the window server gave the "
                                 "server; one Escape at the dialog; it is gone after the reply and 1.5 s "
                                 "later"),
    "menu_over_dialog": (candidate_menu_over_dialog, "the reading names the menu over our dialog; an Escape "
                                                     "at the menu then one at the dialog; both are gone "
                                                     "after the reply and 1.5 s later"),
    "unidentified": (candidate_unidentified, "the reading names the menu over a window it did not open; it "
                                             "refuses with unidentified_dialog_present and sends nothing, "
                                             "so the menu is still open after the reply and 1.5 s later"),
}

# The candidate's own holds the two rows without a control are checked against: nothing against the
# menu hold (which sent an Escape), unidentified against the menu hold (which settled).
COUNTEREXAMPLE_OF = {"nothing": "menu", "unidentified": "menu"}


def host_block(worktree):
    result = subprocess.run([sys.executable, os.path.join(worktree, "Scripts", "observation_host.py")],
                            capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"error": (result.stderr or "")[-300:]}


def main():
    args = arguments()
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    # live_993's main binds this module global for its own helpers; set it the same way.
    setattr(L993, "logic_canon", logic_canon)
    E.REPO = args.worktree
    E.BIN = args.candidate
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    if E.screen_is_locked() is not False:
        sys.exit("cannot run: the screen is locked or its state did not read; nothing was sent to Logic")
    others = subprocess.run(["/usr/bin/pgrep", "-fl", "LogicProMCP"], capture_output=True, text=True)
    if others.stdout.strip():
        sys.exit(f"cannot run: a LogicProMCP process is already running and would hold the MCU "
                 f"ports: {others.stdout.strip()[:300]}")
    sites, appearances = hold_names(args.worktree)
    if len(sites) != 12 or len(appearances) != 2:
        sys.exit(f"cannot run: read {len(sites)} site names and {len(appearances)} appearance names "
                 "from the sources, not 12 and 2")
    names = sites + sorted(appearances)

    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    ev.note("942/binaries", {"candidate": args.candidate, "candidate_sha256": sha256_of(args.candidate),
                             "control": args.control, "control_sha256": sha256_of(args.control),
                             "lprojs": args.lprojs, "names": names})
    runs, failures = {}, {}
    # One rotation over every hold of both binaries, so the fourteen names cycle across screens,
    # binaries and languages rather than each binary restarting at the first site.
    rotation = iter(range(10 ** 6))
    recording = ev.record_screen(seconds=RECORDING_SECONDS_PER_LANGUAGE * len(args.lprojs) + 120)
    restored = {}
    try:
        for lproj in args.lprojs:
            row = runs[lproj] = {}
            tag = f"942/{lproj}"
            language = L993.switch_to(lproj, force=True)
            row["launch"] = language
            if language.get("arrange_window") is None \
                    or language.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                failures[lproj] = "the fixture did not open in this language"
                break
            row["host"] = host_block(args.worktree)
            path, kb = P.menu_path(), keyboard_item()
            row["menu_path"], row["keyboard_item"] = path, kb
            if path is None or kb is None:
                failures[lproj] = f"a menu path did not resolve: go to {path!r}, keyboard {kb!r}"
                break
            for role, binary, kinds in (("candidate", args.candidate, CANDIDATE_HOLDS),
                                        ("control", args.control, CONTROL_HOLDS)):
                row[role] = run_binary(ev, role, binary, kinds, names, rotation, path, kb,
                                       args.worktree, appearances, tag)
                ev.note(f"{tag}/{role}", row[role])
                if row[role].get("error"):
                    failures[lproj] = f"{role}: {row[role]['error']}"
                    break
            ev.note(tag, {"host": row["host"], "launch": language, "menu_path": path, "keyboard_item": kb})
            if lproj in failures:
                break
    finally:
        try:
            restored = L993.switch_to(L993.RESTORE, force=True)
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = L993.language_setting()
        restored["window_names_after_restore"] = L993.window_names()
        restored["ok"] = (restored.get("arrange_window") is not None
                          and restored["language_setting_after_restore"][:1] == [L993.CODES[L993.RESTORE]]
                          and restored["arrange_window"] in (restored["window_names_after_restore"] or []))
        ev.restored("942/Logic-language-restored-to-Korean", restored["ok"], repr(restored))
        ev.stop_recording(recording)

    ev.note("942/locale-failures", failures)
    for lproj in args.lprojs:
        row = runs.get(lproj) or {}
        candidate, control = row.get("candidate") or {}, row.get("control") or {}
        for kind in CANDIDATE_HOLDS:
            predicate, expected = CANDIDATE_PREDICATES[kind]
            counter = candidate.get(COUNTEREXAMPLE_OF[kind]) if kind in COUNTEREXAMPLE_OF else control.get(kind)
            ev.falsifiable(f"942/{lproj}/candidate/{kind}", predicate, candidate.get(kind), counter,
                           f"held on {kind}: {expected}",
                           mutation="remove the settlement block after gotoPositionViaDialog in "
                                    "gotoPositionViaBarSlider (the control binary): no settlement object "
                                    "is carried and nothing arranged is closed")
        for kind in CONTROL_HOLDS:
            ev.falsifiable(f"942/{lproj}/control/{kind}", control_left(kind), control.get(kind),
                           candidate.get(kind),
                           f"held on {kind}, the binary without the settlement carries no settlement "
                           "object and leaves what was arranged on screen after the reply and 1.5 s later",
                           mutation="none: this is the positive control; a screen that closed itself "
                                    "would fail it and void the candidate check")
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"written": out, "is_clean": clean, "failures": failures,
                      "korean_restored": restored.get("ok")}, ensure_ascii=False))
    return 0 if clean and not failures else 1


if __name__ == "__main__":
    sys.exit(main())
