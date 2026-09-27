"""Screen conditions, sampled per check, each a raw observation.

What one `sample()` holds, and where the knowledge came from:

- `screen_locked`: CGSSessionScreenIsLocked from CGSessionCopyCurrentDictionary. A locked screen
  makes the three AX paths disagree about the same Logic (reference_locked_screen_makes_ax_paths_
  disagree; evidence.py:216-251). The key is ABSENT while unlocked (measured 2026-09-27: the
  dictionary held kCGSSessionOnConsoleKey and no lock key), so absence reads False; a dictionary
  that could not be copied reads unreadable. evidence.py samples this once at import (:253); here
  it is sampled at every call, which is what "per check" means.
- `frontmost`: `lsappinfo front`, then its name, pid and bundle id.
- `windows`: every on-screen window with layer > 0 from CGWindowListCopyWindowInfo, owner and
  layer kept. The levels are READ from CGWindowLevelForKey at sample time, not typed: pop-up menu
  101, modal panel 8, help 200 on this machine (measured 2026-09-27). A Logic-owned window in
  [pop-up menu, help) is an open menu -- live_993 measured menus at 101 and 102
  (live_993:186-205) and an open menu wedges AppleEvents (reference_open_menu_wedges_appleevents_
  at_layer_101). A Logic-owned window at the modal panel level is a modal candidate without AX
  (evidence.py:586-612, reference_logic_modal_poisons_every_ax_reading).
- `ax_modal`: per Logic window, role, subrole, title, AXModal, and whether it has a sheet. An
  AXHelpTag is a tooltip, not a modal (evidence.py:486-501, reference_exit1_with_all_checks_green:
  one help tag made every check cannot-tell in every language). -25204 is retried once
  (evidence.py:618-629). Logic does not vend AXSheets (reference_logic_does_not_vend_axsheets), so a
  sheet is found by an AXChildren role, as evidence.py:410-472 does, to a bounded depth.

`clean_state()` returns the sample and a list of dirt; `classify()` is the pure part, and is what
the offline tests drive with recorded samples. `settle_to_clean()` sends Escape ONLY while a menu is
measured open, because with no menu open Escape cancels a dialog instead
(reference_escape_closes_menu_before_modal_dialog), and records every key it sent.
"""

from . import obs

LOGIC_OWNER = "Logic Pro"
LOGIC_BUNDLE = "com.apple.logic10"

# CGWindowLevelKey enum values (CGWindowLevel.h); the LEVELS are read through CGWindowLevelForKey.
_LEVEL_KEYS = {"modal_panel": 10, "popup_menu": 11, "help": 16}

_ESCAPE_KEY_CODE = 53
_SHEET_SEARCH_DEPTH = 6


def is_logic_owner(name):
    """Measured 2026-08-17 (evidence.py:196-203): Korean Logic's owner name carries a NO-BREAK SPACE."""
    return (name or "").replace(" ", " ") == LOGIC_OWNER


# ---------------------------------------------------------------------------------------------
# readers
# ---------------------------------------------------------------------------------------------

def read_levels():
    try:
        from . import cfbridge
        _, cg, _ = cfbridge.libs()
        return obs.readable({name: int(cg.CGWindowLevelForKey(key))
                             for name, key in _LEVEL_KEYS.items()})
    except Exception as exc:  # noqa: BLE001
        return obs.unreadable(f"CGWindowLevelForKey: {exc!r}")


def read_screen_locked():
    try:
        from . import cfbridge
        _, cg, _ = cfbridge.libs()
        session = cfbridge.copy_owned(cg.CGSessionCopyCurrentDictionary)
    except Exception as exc:  # noqa: BLE001
        return obs.unreadable(f"CGSessionCopyCurrentDictionary: {exc!r}")
    if not isinstance(session, dict):
        return obs.unreadable("CGSessionCopyCurrentDictionary returned no dictionary",
                              raw=session)
    return obs.readable(bool(session.get("CGSSessionScreenIsLocked", False)), session=session)


def read_windows():
    """On-screen windows with layer > 0, raw (bounds kept)."""
    try:
        from . import cfbridge
        _, cg, _ = cfbridge.libs()
        # kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, as evidence.py:206.
        listed = cfbridge.copy_owned(cg.CGWindowListCopyWindowInfo, 1 | 16, 0)
    except Exception as exc:  # noqa: BLE001
        return obs.unreadable(f"CGWindowListCopyWindowInfo: {exc!r}")
    if not isinstance(listed, list):
        return obs.unreadable("CGWindowListCopyWindowInfo returned no array", raw=listed)
    out = []
    for window in listed:
        layer = window.get("kCGWindowLayer")
        if not isinstance(layer, int) or layer <= 0:
            continue
        out.append({"owner": window.get("kCGWindowOwnerName"),
                    "owner_pid": window.get("kCGWindowOwnerPID"),
                    "layer": layer, "name": window.get("kCGWindowName"),
                    "number": window.get("kCGWindowNumber"),
                    "bounds": window.get("kCGWindowBounds")})
    return obs.readable(out, windows_listed=len(listed))


def read_frontmost():
    front = obs.run(["/usr/bin/lsappinfo", "front"], 10)
    asn = (front.get("stdout") or "").strip()
    if front["returncode"] != 0 or not asn:
        return obs.unreadable("lsappinfo front did not name an application", raw=front)
    info = obs.run(["/usr/bin/lsappinfo", "info", "-only", "name", "-only", "pid",
                    "-only", "bundleid", asn], 10)
    if info["returncode"] != 0:
        return obs.unreadable("lsappinfo info failed", raw=info)
    fields = {}
    for line in (info.get("stdout") or "").splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            fields[key.strip().strip('"')] = value.strip().strip('"')
    pid = fields.get("pid")
    return obs.readable({"name": fields.get("LSDisplayName"),
                         "pid": int(pid) if pid and pid.isdigit() else pid,
                         "bundle_id": fields.get("CFBundleIdentifier")},
                        asn=asn, raw=info.get("stdout"))


def logic_pids():
    found = obs.run(["/usr/bin/pgrep", "-x", LOGIC_OWNER], 10)
    if found["returncode"] not in (0, 1):
        return obs.unreadable("pgrep failed", raw=found)
    return obs.readable([int(p) for p in (found["stdout"] or "").split() if p.isdigit()])


def _sheet_under(ax, element, depth):
    """True when an AXSheet is found below, False after a complete search, else the failing status."""
    from . import cfbridge
    kids = ax.elements(element, "AXChildren")
    if kids["elements"] is None:
        return False if kids["status"] in cfbridge.AX_ANSWERS else kids["status"]
    unreadable = None
    for kid in kids["elements"]:
        role, error = cfbridge.text_of(ax.value(kid, "AXRole"))
        if error is not None:
            unreadable = unreadable or error
            continue
        if role == "AXSheet":
            return True
        if depth > 0:
            below = _sheet_under(ax, kid, depth - 1)
            if below is True:
                return True
            if below is not False:
                unreadable = unreadable or below
    return False if unreadable is None else unreadable


def read_ax_modal(pid, retried=False):
    """Every AXWindows entry of `pid`, raw: role, subrole, title, AXModal, sheet search result."""
    try:
        from . import cfbridge
        ax = cfbridge.AX(pid)
    except Exception as exc:  # noqa: BLE001
        return obs.unreadable(f"AX session: {exc!r}")
    try:
        if not ax.app:
            return obs.unreadable("AXUIElementCreateApplication returned NULL", pid=pid)
        listed = ax.elements(ax.app, "AXWindows")
        if listed["elements"] is None:
            if listed["status"] == cfbridge.AX_CANNOT_COMPLETE and not retried:
                ax.close()
                return {**read_ax_modal(pid, retried=True), "retried_after": listed["status"]}
            return obs.unreadable("AXWindows", status=listed["status"], pid=pid)
        windows = []
        for window in listed["elements"]:
            row = {}
            for name in ("AXRole", "AXSubrole", "AXTitle"):
                text, error = cfbridge.text_of(ax.value(window, name))
                row[name] = text
                if error is not None:
                    row[f"{name}_error"] = error
            modal = ax.value(window, "AXModal")
            row["AXModal"] = modal["value"] if modal["status"] == 0 else None
            row["AXModal_status"] = modal["status"]
            row["sheet"] = (None if row["AXRole"] == "AXHelpTag"
                            else _sheet_under(ax, window, _SHEET_SEARCH_DEPTH))
            windows.append(row)
        return obs.readable(windows, pid=pid, retried=retried)
    finally:
        ax.close()


def sample(pid=None, with_ax=True):
    """One raw sample of every condition, stamped."""
    started = obs.now()
    pids = logic_pids()
    if pid is None and pids["readable"] and len(pids["value"]) == 1:
        pid = pids["value"][0]
    out = {"t": started, "levels": read_levels(), "screen_locked": read_screen_locked(),
           "frontmost": read_frontmost(), "windows": read_windows(), "logic_pids": pids}
    if with_ax:
        out["ax_modal"] = (read_ax_modal(pid) if pid else
                           obs.unreadable("no single Logic pid to ask", logic_pids=pids))
    out["elapsed_s"] = obs.now() - started
    return out


# ---------------------------------------------------------------------------------------------
# classification: pure, driven offline by recorded samples
# ---------------------------------------------------------------------------------------------

def classify(snapshot, require_logic_frontmost=False):
    """The dirt in one sample, as a list of {kind, ...raw}. Empty means clean.

    An unreadable condition is dirt of its own kind (`*_unreadable`): a condition nobody could read
    was not observed clean.
    """
    dirt = []
    levels = snapshot.get("levels") or {}
    lock = snapshot.get("screen_locked") or {}
    if not lock.get("readable"):
        dirt.append({"kind": "screen_lock_unreadable", "cause": lock.get("cause")})
    elif lock.get("value") is True:
        dirt.append({"kind": "screen_locked"})

    windows = snapshot.get("windows") or {}
    if not levels.get("readable"):
        dirt.append({"kind": "window_levels_unreadable", "cause": levels.get("cause")})
    elif not windows.get("readable"):
        dirt.append({"kind": "window_list_unreadable", "cause": windows.get("cause")})
    else:
        level = levels["value"]
        for window in windows["value"]:
            if not is_logic_owner(window.get("owner")):
                continue
            layer = window.get("layer")
            if level["popup_menu"] <= layer < level["help"]:
                dirt.append({"kind": "menu_open", "window": window})
            elif layer == level["modal_panel"]:
                dirt.append({"kind": "modal_panel_level", "window": window})

    ax_modal = snapshot.get("ax_modal")
    if ax_modal is not None:
        if not ax_modal.get("readable"):
            dirt.append({"kind": "ax_modal_unreadable", "cause": ax_modal.get("cause"),
                         "status": ax_modal.get("status")})
        else:
            for window in ax_modal["value"]:
                # No role skip here: a tooltip answers AXModal -25205 and gets no sheet search in
                # read_ax_modal, so it adds no dirt; a skip on its role was measured dead.
                if window.get("sheet") is True:
                    dirt.append({"kind": "ax_sheet", "window": window})
                elif window.get("sheet") not in (False, None):
                    dirt.append({"kind": "ax_sheet_unreadable", "window": window})
                if window.get("AXModal") is True:
                    dirt.append({"kind": "ax_modal", "window": window})
                elif window.get("AXModal") is None and window.get("AXModal_status") not in (-25205, -25212):
                    dirt.append({"kind": "ax_modal_unreadable", "window": window})

    if require_logic_frontmost:
        front = snapshot.get("frontmost") or {}
        if not front.get("readable"):
            dirt.append({"kind": "frontmost_unreadable", "cause": front.get("cause")})
        elif (front["value"] or {}).get("bundle_id") != LOGIC_BUNDLE:
            dirt.append({"kind": "logic_not_frontmost", "frontmost": front["value"]})
    return dirt


def clean_state(pid=None, require_logic_frontmost=False):
    """{"observation": <sample>, "dirt": [...]}: the reading and what in it is not clean."""
    snapshot = sample(pid)
    return {"observation": snapshot,
            "dirt": classify(snapshot, require_logic_frontmost=require_logic_frontmost)}


def send_escape():
    return obs.osascript(f'tell application "System Events" to key code {_ESCAPE_KEY_CODE}', 8)


def settle_to_clean(timeout_s=10.0, max_escapes=3, pid=None, sampler=None, escaper=None):
    """Sample until clean or the deadline; send Escape only when a menu is measured open.

    Returns {"initial", "actions", "final", "timed_out", "escapes_sent"}; every Escape is an action
    with the sample that justified it. Dirt that is not an open menu is never acted on here -- it is
    reported, because acting on a modal without knowing what it is can cancel someone's dialog.
    """
    sampler = sampler or (lambda: clean_state(pid))
    escaper = escaper or send_escape
    started = obs.now()
    initial = sampler()
    current, actions, escapes = initial, [], 0
    while current["dirt"]:
        menus = [d for d in current["dirt"] if d["kind"] == "menu_open"]
        if obs.now() - started >= timeout_s:
            break
        if menus and escapes < max_escapes:
            actions.append({"t": obs.now(), "action": "escape", "because": menus,
                            "result": escaper()})
            escapes += 1
        elif not menus:
            break
        waited = obs.wait_until(sampler, min(2.0, max(0.1, timeout_s - (obs.now() - started))),
                                interval_s=0.25, done=lambda s: not any(
                                    d["kind"] == "menu_open" for d in s["dirt"]))
        current = waited["last"]
        if escapes >= max_escapes and any(d["kind"] == "menu_open" for d in current["dirt"]):
            break
    return {"initial": initial, "actions": actions, "final": current, "escapes_sent": escapes,
            "timed_out": bool(current["dirt"]) and obs.now() - started >= timeout_s,
            "elapsed_s": obs.now() - started}

