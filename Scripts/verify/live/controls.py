"""Positive controls that change the fixture and read the change back through the probe.

A positive control is a reading a broken probe cannot produce (PR #1033 review, coverage gap): a
probe that returns zeros or nothing must FAIL it. So each control here puts a known, non-empty
state into the reset fixture, reads it through the registered probe, then puts the state back and
reads again. The judgement is the probe's `known` predicate in probes.REGISTRY, over what is
recorded here; nothing in this module decides a pass.

  track_flags_ax    Mute, Solo and Record Enable of the fixture's `flag_track`, each alone, set
                    through the product's logic_tracks tools and confirmed by the probe with a
                    bounded wait, then unset the same way. The probe must see that flag on that
                    track and nothing else set, then every track at 0 again.
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

FLAG_WAIT_S = 30.0
TOOL_TIMEOUT_S = 90.0
CALL_WAIT_S = 60.0
CALL_RETRY_S = 3.0
MENU_WAIT_S = 8.0
MENU_WALK_DEPTH = 14
SEND_WAIT_S = 10.0


# ---------------------------------------------------------------------------------------------
# track_flags_ax
# ---------------------------------------------------------------------------------------------

def _tool_succeeded(call):
    return isinstance(call.get("body"), dict) and call["body"].get("success") is True


def set_track_flag(server, lproj, spec, flag, value):
    """logic_tracks <flag> on the fixture's flag_track, retried (bounded) while the product reports
    no success, then a bounded wait for the probe to read that flag alone set (value 1) or nothing
    set (value 0). Every attempt and every probe sample is kept, raw.

    The retry is for the builder, not the probe: on 2026-09-27 (de) the first Mute after the server
    started came back channels_exhausted in 1.5 s, and the Solo sent after the 30 s probe wait
    worked through the MCU rung (verify-live-selftest/c07f3f1c)."""
    index = spec["flag_track"]
    calls = obs.wait_until(
        lambda: server.tool("logic_tracks", flag, {"index": index, "enabled": bool(value)},
                            timeout_s=TOOL_TIMEOUT_S),
        CALL_WAIT_S, interval_s=CALL_RETRY_S, done=_tool_succeeded)
    shown = flag if value else None
    waited = obs.wait_until(lambda: probes.run("track_flags_ax", {"lproj": lproj}), FLAG_WAIT_S,
                            interval_s=1.0, done=lambda run: probes.flags_show(spec, run, shown))
    return {"flag": flag, "index": index, "value": value,
            "calls": [sample["result"] for sample in calls["samples"]],
            "call_wait": {k: calls[k] for k in ("timed_out", "elapsed_s", "polls")},
            "wait": {k: waited[k] for k in ("timed_out", "elapsed_s", "polls")},
            "last": waited["last"]}


def track_flags_control(lproj, server, spec):
    """Each flag in turn, alone: set, read, unset, read. One at a time because Logic draws a soloed
    track's own Mute as 0 while it is soloed (measured 2026-09-27 ko: mute 1 -> 0 on solo, back to
    1 after), so flags set together do not read back as set together."""
    record = {"target": spec["flag_track"],
              "pre": probes.run("track_flags_ax", {"lproj": lproj}), "cycles": []}
    for flag in probes.FLAG_COMMANDS:
        cycle = {"flag": flag, "set": set_track_flag(server, lproj, spec, flag, 1)}
        cycle["post"] = probes.run("track_flags_ax", {"lproj": lproj})
        cycle["unset"] = set_track_flag(server, lproj, spec, flag, 0)
        cycle["after"] = probes.run("track_flags_ax", {"lproj": lproj})
        record["cycles"].append(cycle)
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


def select_send_stereo(lproj, strip_index):
    """Press the strip's first send slot and choose Apple's exact Stereo Output row."""
    record = {"strip": strip_index}
    pid = probes._single_logic_pid(None)
    record["pid"] = pid
    stereo = live_locale.apple_row(lproj, "Stereo Output")
    record["stereo_row"] = stereo
    if not pid["readable"] or not stereo["readable"]:
        record["cause"] = "no single Logic pid, or Apple's Stereo Output row did not resolve"
        return record
    before = probes.run("routing_slots_ax", {"lproj": lproj})
    record["before"] = {k: before.get(k) for k in ("t", "elapsed_s")}
    observation = before.get("observation") or {}
    strips = observation.get("strips") or []
    if strip_index >= len(strips) or not strips[strip_index]["sends"]:
        record["cause"] = "the strip or its send slot is not in the probe's reading"
        return record
    sends = strips[strip_index]["sends"]
    if len(sends) != 1 or sends[0].get("occupied") is not False:
        record["cause"] = "the strip does not have exactly one sole empty Send setup slot"
        return record
    send = sends[0]
    record["send_slot"] = {k: send.get(k) for k in ("description", "help", "path", "occupied")}
    ax = None
    sessions = []
    pressed = False
    try:
        ax = cfbridge.AX(pid["value"])
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
        fresh = probes.run("routing_slots_ax", {"lproj": lproj})
        fresh_observation = fresh.get("observation") or {}
        fresh_strips = fresh_observation.get("strips") or []
        record["pre_press"] = {k: fresh.get(k) for k in ("t", "elapsed_s")}
        if len(fresh_strips) != len(strips) or strip_index >= len(fresh_strips):
            record["cause"] = "the pre-press routing walk no longer has the same strip membership"
            return record
        fresh_sends = fresh_strips[strip_index].get("sends") or []
        if len(fresh_sends) != 1 or fresh_sends[0].get("occupied") is not False:
            record["cause"] = "the pre-press routing walk no longer has one sole empty Send slot"
            return record
        fresh_send = fresh_sends[0]
        record["pre_press"]["send_slot"] = {
            k: fresh_send.get(k) for k in ("description", "help", "path", "occupied")
        }
        compared = ("description", "help", "path", "occupied")
        if any(fresh_send.get(key) != send.get(key) for key in compared):
            record["cause"] = "the pre-press Send slot no longer matches the initially read slot"
            return record
        fresh_found = ax.element_at(fresh_send["path"])
        if fresh_found["element"] is None:
            record["cause"] = "the pre-press Send slot path no longer resolves"
            record["pre_press"]["resolve"] = {
                k: fresh_found[k] for k in fresh_found if k != "element"
            }
            return record
        fresh_help, _ = cfbridge.text_of(ax.value(fresh_found["element"], "AXHelp"))
        if fresh_help != fresh_send["help"]:
            record["cause"] = "the pre-press element does not carry the Send slot's help"
            record["pre_press"]["help_at_path"] = fresh_help
            return record
        if not ax.same(found["element"], fresh_found["element"]):
            record["cause"] = "the pre-press Send slot identity replaced the initially read element"
            return record
        started = obs.now()
        # Even a failing AXPress may have opened the menu. From this boundary every exit measures
        # and cleans the screen before the actuator can return a usable record.
        pressed = True
        record["press"] = {"status": ax.perform(fresh_found["element"], "AXPress"),
                           "elapsed_s": obs.now() - started}
        ax.close()
        ax = None

        def stereo_items():
            session, menus, items = _menu_items(pid["value"])
            sessions.append(session)
            matching = [item for item in items
                        if item["enabled"] is True and item["title"] == stereo["value"]]
            return ({"menus": menus, "items": len(items), "matching": matching}
                    if matching else None)

        waited = obs.wait_until(stereo_items, MENU_WAIT_S, interval_s=0.5)
        record["menu_wait"] = {k: waited[k] for k in ("timed_out", "elapsed_s", "polls")}
        found_menu = waited["last"]
        if not isinstance(found_menu, dict) or "matching" not in found_menu:
            record["cause"] = "no enabled Stereo Output item appeared in an open menu"
            return record
        chosen = found_menu["matching"]
        record["menu"] = {"menus": found_menu["menus"], "items": found_menu["items"],
                          "stereo_items": len(chosen)}
        if len(chosen) != 1:
            record["cause"] = "the Stereo Output title is not unique; a pick would be a guess"
            return record
        record["selected"] = chosen[0]["title"]
        record["select_status"] = sessions[-1].perform(chosen[0]["element"], "AXPress")
    finally:
        if ax is not None:
            ax.close()
        for session in sessions:
            session.close()
        if pressed:
            try:
                settled = screen.settle_to_clean(timeout_s=8.0)
                record["settle"] = settled
                if (settled.get("final") or {}).get("dirt") != []:
                    record["cause"] = (record.get("cause") or
                                       "measured menu cleanup did not reach a clean screen")
            except Exception as exc:  # noqa: BLE001 - cleanup failure is an unreadable record
                record["settle"] = {"raised": repr(exc)}
                record["cause"] = (record.get("cause") or
                                   "measured menu cleanup could not be read")
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


# ---------------------------------------------------------------------------------------------
# undo_entry_ax
# ---------------------------------------------------------------------------------------------

def undo_entry_control(lproj, server, spec):
    """A different verified mutation moves the Cmd-Z row; then restore the track flag."""
    record = {"pre": probes.run("undo_entry_ax", {"lproj": lproj})}
    record["set"] = set_track_flag(server, lproj, spec, "mute", 1)
    record["post"] = probes.run("undo_entry_ax", {"lproj": lproj})
    record["unset"] = set_track_flag(server, lproj, spec, "mute", 0)
    record["after"] = probes.run("undo_entry_ax", {"lproj": lproj})
    return record


CONTROLS = {
    "track_flags_ax": track_flags_control,
    "routing_slots_ax": routing_slots_control,
    "undo_entry_ax": undo_entry_control,
}


def drive(name, lproj, server):
    """Run the named probe's positive control on its fixture. Raw record."""
    probe = probes.REGISTRY[name]
    spec = fixture.spec(probe["positive_control"]["fixture"])
    started = obs.now()
    record = CONTROLS[name](lproj, server, spec)
    return {"probe": name, "fixture": spec["name"], "lproj": lproj, "t": started,
            "elapsed_s": obs.now() - started, "control": record}
