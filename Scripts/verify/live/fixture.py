"""Named fixtures: each a file on disk, a builder, a reader, and a declared fingerprint.

Two are named, one per pilot, and both are the same project file -- the locale-campaign project
`~/Music/Logic/lpm-locale-campaign.logicx`, which live_993 (:51), probe_993_1004 (:74) and
f291r1's live_291 (:156) open by path, and on which the #1020 runs were measured (19 tracks:
scratchpad/ev1020new/ko.evidence.json, record `1020/track-census`):

  locale_campaign_19     #1020 (Scripts/livekit/live_1020_mcu_set_arm_is_a_set.py needs >= 17
                         tracks, tracks 15 and 16 disarmed; its docstring calls it "the 19-track
                         fixture"). Declared: 19 tracks, the names below, nothing armed, muted or
                         soloed.
  locale_campaign_mixer  #291 (scratchpad/live291.sh drives f291r1's live_291 on it). The same
                         project with the Mixer shown: 21 strips (19 tracks, Stereo Out, Master),
                         measured 2026-09-27 (ko) by probes.routing_slots_ax.

The builder opens the pinned file through LaunchServices (`open -a`, as every harness above does)
and, for the Mixer fixture, shows the Mixer with the X key (f291r1 live_291:1044-1049: "the same key
in every language"), sent as a System Events keystroke -- never a coordinate click
(feedback_multimonitor_no_coordinate_clicks). It does not create the project from nothing: the
fixture is the file, and a missing file is reported, not rebuilt.

The reset is Don't Save + reopen from disk (locale.quit_logic, locale.launch): the file on disk is
the reference state. The reader then takes a fingerprint (track count, names, flags from the AX
probe; types from the product's logic://tracks when a server is given, labelled as the product's)
and `fingerprint_matches` compares it with the declaration, so a reset is VERIFIED by a reading,
not assumed (feedback_reset_the_fixture_before_measuring_a_rate).
"""

import os

from . import obs, probes
from . import locale as live_locale

CAMPAIGN = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
CAMPAIGN_NAMES = (["Absolute Zero", "Audio 1"] + ["Deluxe Classic"] * 9 + ["Studio Grand"] * 8)

FIXTURES = {
    "locale_campaign_19": {
        "name": "locale_campaign_19", "path": CAMPAIGN, "pilot": "#1020",
        "track_count": 19, "names": CAMPAIGN_NAMES, "types": None, "mixer_strips": None,
        # The track the positive control mutes, solos and arms: an instrument track the product
        # set Mute on through its MCU rung on 2026-09-27 (ko), not track 0, the must-FAIL arm's.
        "flag_track": 2,
    },
    "locale_campaign_mixer": {
        "name": "locale_campaign_mixer", "path": CAMPAIGN, "pilot": "#291",
        "track_count": 19, "names": CAMPAIGN_NAMES, "types": None, "mixer_strips": 21,
        # Audio 1's strip: the only one with an input slot, and the one #291 sent to Bus 256
        # (records 291e/<lproj>/target {"strip": 1} and 291e/<lproj>/send-after).
        "input_strip": 1,
    },
}

MIXER_WAIT_S = 10.0


def spec(name):
    return FIXTURES[name]


def press_mixer_key():
    """Activate Logic and send X (f291r1 live_291:1044-1049). Keyboard, not coordinates."""
    return obs.run(["/usr/bin/osascript", "-e", 'tell application "Logic Pro" to activate',
                    "-e", "delay 0.5", "-e",
                    'tell application "System Events" to keystroke "x"'], 15)


def mixer_reading(lproj):
    return probes.run("routing_slots_ax", {"lproj": lproj})


def ensure_mixer(lproj, shown=True):
    """Show (or hide) the Mixer, verified by the routing-slot probe; every press recorded."""
    first = mixer_reading(lproj)
    record = {"want_shown": shown, "first": first, "presses": []}

    def found(reading):
        observation = reading.get("observation") or {}
        return bool(observation.get("readable")) and bool(observation.get("mixer_found")) == shown

    if found(first):
        record["final"] = first
        return record
    for _ in range(2):
        record["presses"].append(press_mixer_key())
        waited = obs.wait_until(lambda: mixer_reading(lproj), MIXER_WAIT_S, interval_s=0.5,
                                done=found)
        record["final"] = waited["last"]
        record["wait"] = {k: waited[k] for k in ("timed_out", "elapsed_s", "polls")}
        if not waited["timed_out"]:
            break
    return record


def build(name, lproj):
    """Open the fixture (and show the Mixer when it declares one). Raw record."""
    fx = FIXTURES[name]
    record = {"fixture": name, "path": fx["path"], "exists": os.path.isdir(fx["path"])}
    if not record["exists"]:
        record["cause"] = "the fixture file is missing; this builder opens it and does not create it"
        return record
    title = live_locale.expected_title(lproj, fx["path"])
    record["title"] = title
    if not title["readable"]:
        return record
    names = live_locale.window_names()
    record["window_names_before"] = names
    if not (names["readable"] and title["value"] in names["value"]):
        record["launch"] = live_locale.launch(fx["path"], title["value"])
    if fx["mixer_strips"]:
        record["mixer"] = ensure_mixer(lproj, shown=True)
    return record


def product_tracks(server):
    """logic://tracks after a refresh, through the product: raw, labelled as the product's."""
    refresh = server.tool("logic_system", "refresh_cache", timeout_s=60)
    tracks = server.resource("logic://tracks", timeout_s=60)
    return {"source": "product logic://tracks", "refresh": refresh, "tracks": tracks}


def read(name, lproj, server=None):
    """The fixture's fingerprint now: raw probe output plus the derived fingerprint."""
    fx = FIXTURES[name]
    flags = probes.run("track_flags_ax", {"lproj": lproj, "fixture": fx["path"]})
    observation = flags.get("observation") or {}
    fingerprint = {"track_count": None, "names": None, "flags": None, "types": None,
                   "mixer_strips": None}
    if observation.get("readable"):
        fingerprint.update(
            track_count=observation["track_count"],
            names=[t["name"] for t in observation["tracks"]],
            flags=[{f: t[f] for f in ("arm", "mute", "solo")} for t in observation["tracks"]])
    record = {"fixture": name, "lproj": lproj, "track_flags": flags, "fingerprint": fingerprint}
    if fx["mixer_strips"]:
        mixer = mixer_reading(lproj)
        record["mixer"] = mixer
        mo = mixer.get("observation") or {}
        if mo.get("readable") and mo.get("mixer_found"):
            fingerprint["mixer_strips"] = len(mo["strips"])
    if server is not None:
        product = product_tracks(server)
        record["product"] = product
        body = (product["tracks"] or {}).get("body") or {}
        rows = [r for r in body.get("data") or [] if isinstance(r, dict)]
        if rows:
            fingerprint["types"] = [r.get("type") for r in sorted(
                rows, key=lambda r: r.get("id") if isinstance(r.get("id"), int) else 1 << 30)]
    return record


def fingerprint_matches(fx, fingerprint):
    """The reset predicate: the reading equals the declaration on every declared field."""
    if fingerprint.get("track_count") != fx["track_count"] or fingerprint.get("names") != fx["names"]:
        return False
    flags = fingerprint.get("flags")
    if not isinstance(flags, list) or any(v != 0 for row in flags for v in row.values()):
        return False
    if fx["types"] is not None and fingerprint.get("types") != fx["types"]:
        return False
    if fx["mixer_strips"] is not None and fingerprint.get("mixer_strips") != fx["mixer_strips"]:
        return False
    return True


def reset(name, lproj, server=None):
    """Don't Save + reopen from disk, rebuild, then read. Judge it with `fingerprint_matches`."""
    fx = FIXTURES[name]
    record = {"fixture": name, "lproj": lproj, "t": obs.now()}
    record["quit"] = live_locale.quit_logic(fx["path"])
    if not record["quit"].get("quit"):
        record["cause"] = "Logic did not quit"
        return record
    record["build"] = build(name, lproj)
    record["read"] = read(name, lproj, server)
    return record
