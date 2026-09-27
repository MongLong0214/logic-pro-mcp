"""Positive controls that change the fixture and read the change back through the probe.

A positive control is a reading a broken probe cannot produce (PR #1033 review, coverage gap): a
probe that returns zeros or nothing must FAIL it. So each control here puts a known, non-empty
state into the reset fixture, reads it through the registered probe, then puts the state back and
reads again. The judgement is the probe's `known` predicate in probes.REGISTRY, over what is
recorded here; nothing in this module decides a pass.

  track_flags_ax    Mute, Solo and Record Enable of the fixture's `flag_track` set through the
                    product's logic_tracks tools (the MCP builder the brief allows), each confirmed
                    by the probe with a bounded wait, then unset the same way. The probe must see
                    exactly that track change, and see every track at 0 again afterwards.
  routing_slots_ax  The known input label of the fixture's `input_strip` (Apple's `Input` row + " 1":
                    #291 read 입력 1 / Eingang 1 / Input 1 / 入力 1 on strip 1 in ko/de/en/ja,
                    /Users/isaac/lpm-evidence/291-ten/<lproj>/*/live_291_*.evidence.json), and a send:
                    the strip's first send slot is pressed by AX, and the highest-numbered bus in its
                    menu is chosen (Apple's `Bus` row + a number; #291 chose 버스 256 / Bus 256 the
                    same way, record 291e/<lproj>/send/menu). The probe must see that strip, and only
                    it, with an occupied send; the fixture is then reset (Don't Save + reopen) and
                    the probe must see no occupied send again.

The send is chosen through the menu the slot opens, by the item's title: no coordinates. Menus the
press leaves open are closed by screen.settle_to_clean, which sends Escape only for a measured menu.
"""

import re

from . import cfbridge, fixture, obs, probes, screen
from . import locale as live_locale

FLAG_COMMANDS = ("mute", "solo", "arm")
FLAG_WAIT_S = 30.0
TOOL_TIMEOUT_S = 90.0
MENU_WAIT_S = 8.0
MENU_WALK_DEPTH = 14
SEND_WAIT_S = 10.0


# ---------------------------------------------------------------------------------------------
# track_flags_ax
# ---------------------------------------------------------------------------------------------

def _flag_of(run, index, flag):
    observation = (run or {}).get("observation") or {}
    if not observation.get("readable"):
        return None
    for track in observation["tracks"]:
        if track["index"] == index:
            return track[flag]
    return None


def set_track_flag(server, lproj, index, flag, value):
    """One logic_tracks call, then a bounded wait for the probe to read `value`. Raw record."""
    call = server.tool("logic_tracks", flag, {"index": index, "enabled": bool(value)},
                       timeout_s=TOOL_TIMEOUT_S)
    waited = obs.wait_until(lambda: probes.run("track_flags_ax", {"lproj": lproj}), FLAG_WAIT_S,
                            interval_s=1.0, done=lambda run: _flag_of(run, index, flag) == value)
    return {"flag": flag, "index": index, "value": value, "call": call,
            "wait": {k: waited[k] for k in ("timed_out", "elapsed_s", "polls")},
            "last": waited["last"]}


def track_flags_control(lproj, server, spec):
    target = spec["flag_track"]
    record = {"target": target, "pre": probes.run("track_flags_ax", {"lproj": lproj}),
              "set": [], "unset": []}
    for flag in FLAG_COMMANDS:
        record["set"].append(set_track_flag(server, lproj, target, flag, 1))
    record["post"] = probes.run("track_flags_ax", {"lproj": lproj})
    for flag in FLAG_COMMANDS:
        record["unset"].append(set_track_flag(server, lproj, target, flag, 0))
    record["after"] = probes.run("track_flags_ax", {"lproj": lproj})
    return record


# ---------------------------------------------------------------------------------------------
# routing_slots_ax
# ---------------------------------------------------------------------------------------------

def input_label(lproj, number=1):
    """Apple's `Input` row + " <number>", the label #291 read on the audio strip's input slot."""
    row = live_locale.apple_row(lproj, "Input")
    if not row["readable"]:
        return row
    return obs.readable(f"{row['value']} {number}", row=row)


def _menu_items(pid):
    """Every AXMenuItem under Logic's windows: (title, enabled, element) with an open AX session."""
    ax = cfbridge.AX(pid)
    items, menus = [], 0
    listed = ax.elements(ax.app, "AXWindows")

    def walk(element, depth):
        nonlocal menus
        role, _ = cfbridge.text_of(ax.value(element, "AXRole"))
        if role == "AXMenu":
            menus += 1
        if role == "AXMenuItem":
            title, _ = cfbridge.text_of(ax.value(element, "AXTitle"))
            items.append({"title": title, "enabled": ax.value(element, "AXEnabled")["value"],
                          "element": element})
        if depth >= MENU_WALK_DEPTH:
            return
        for child in ax.elements(element, "AXChildren")["elements"] or []:
            walk(child, depth + 1)

    for window in listed["elements"] or []:
        walk(window, 0)
    return ax, menus, items


def select_send_bus(lproj, strip_index):
    """Press the strip's first send slot and choose the highest-numbered bus. Raw record."""
    record = {"strip": strip_index}
    pid = probes._single_logic_pid(None)
    record["pid"] = pid
    bus = live_locale.apple_row(lproj, "Bus")
    record["bus_row"] = bus
    if not pid["readable"] or not bus["readable"]:
        record["cause"] = "no single Logic pid, or Apple's Bus row did not resolve"
        return record
    before = probes.run("routing_slots_ax", {"lproj": lproj})
    record["before"] = {k: before.get(k) for k in ("t", "elapsed_s")}
    observation = before.get("observation") or {}
    strips = observation.get("strips") or []
    if strip_index >= len(strips) or not strips[strip_index]["sends"]:
        record["cause"] = "the strip or its send slot is not in the probe's reading"
        return record
    send = strips[strip_index]["sends"][0]
    record["send_slot"] = {k: send.get(k) for k in ("description", "help", "path", "occupied")}
    ax = cfbridge.AX(pid["value"])
    try:
        found = ax.element_at(send["path"])
        if found["element"] is None:
            record["cause"] = "the send slot's path no longer resolves"
            record["resolve"] = {k: found[k] for k in found if k != "element"}
            return record
        help_text, _ = cfbridge.text_of(ax.value(found["element"], "AXHelp"))
        if help_text != send["help"]:
            record["cause"] = "the element at the path is not the send slot the probe read"
            record["help_at_path"] = help_text
            return record
        started = obs.now()
        record["press"] = {"status": ax.perform(found["element"], "AXPress"),
                           "elapsed_s": obs.now() - started}
    finally:
        ax.close()

    pattern = re.compile(re.escape(bus["value"]) + r"\s*([0-9]+)")
    sessions = []

    def bus_items():
        session, menus, items = _menu_items(pid["value"])
        sessions.append(session)
        numbered = [(int(m.group(1)), item) for item in items if item["enabled"] is True
                    for m in [pattern.fullmatch(item["title"] or "")] if m]
        return {"menus": menus, "items": len(items), "numbered": numbered} if numbered else None

    try:
        waited = obs.wait_until(bus_items, MENU_WAIT_S, interval_s=0.5)
        record["menu_wait"] = {k: waited[k] for k in ("timed_out", "elapsed_s", "polls")}
        found_menu = waited["last"]
        if not found_menu:
            record["cause"] = "no enabled bus item appeared in an open menu"
            return record
        highest = max(number for number, _ in found_menu["numbered"])
        chosen = [item for number, item in found_menu["numbered"] if number == highest]
        record["menu"] = {"menus": found_menu["menus"], "items": found_menu["items"],
                          "bus_items": len(found_menu["numbered"]), "highest": highest,
                          "titled_highest": len(chosen)}
        if len(chosen) != 1:
            record["cause"] = "the highest bus title is not unique; a pick would be a guess"
            return record
        record["selected"] = chosen[0]["title"]
        record["select_status"] = sessions[-1].perform(chosen[0]["element"], "AXPress")
    finally:
        for session in sessions:
            session.close()
    record["settle"] = screen.settle_to_clean(timeout_s=8.0)
    return record


def _occupied_strips(run):
    observation = (run or {}).get("observation") or {}
    return [index for index, strip in enumerate(observation.get("strips") or [])
            if any(send["occupied"] for send in strip["sends"])]


def routing_slots_control(lproj, server, spec):
    """Known input label and one chosen send, read by the probe; then reset and read again."""
    strip = spec["input_strip"]
    record = {"strip": strip, "input_label": input_label(lproj),
              "pre": probes.run("routing_slots_ax", {"lproj": lproj})}
    record["select"] = select_send_bus(lproj, strip)
    waited = obs.wait_until(lambda: probes.run("routing_slots_ax", {"lproj": lproj}), SEND_WAIT_S,
                            interval_s=0.5, done=lambda run: _occupied_strips(run) == [strip])
    record["post"] = waited["last"]
    record["post_wait"] = {k: waited[k] for k in ("timed_out", "elapsed_s", "polls")}
    record["reset"] = fixture.reset(spec["name"], lproj)
    record["after"] = probes.run("routing_slots_ax", {"lproj": lproj})
    return record


CONTROLS = {
    "track_flags_ax": track_flags_control,
    "routing_slots_ax": routing_slots_control,
}


def drive(name, lproj, server):
    """Run the named probe's positive control on its fixture. Raw record."""
    probe = probes.REGISTRY[name]
    spec = fixture.spec(probe["positive_control"]["fixture"])
    started = obs.now()
    record = CONTROLS[name](lproj, server, spec)
    return {"probe": name, "fixture": spec["name"], "lproj": lproj, "t": started,
            "elapsed_s": obs.now() - started, "control": record}
