"""The fixture registry: what a spec's `fixture.id` means to the runner, and the gate before a row.

A spec names its fixture by id; the note beside it is prose for a reader. What the runner does with
the id is declared here, once, and nowhere else:

    live        the live/fixture.py declaration the live lifecycle opens and resets, or None for a
                fixture only the self-test's fake world has (the live lifecycle refuses those)
    server_env  variables added to the server's environment for every start on this fixture
    ready       what the lifecycle waits on after a start ("mcu": logic://mcu/state connected and
                registered), or None where there is nothing to wait on
    gate        the checks run before every row, over a reading the lifecycle takes:
                "fingerprint"               the track count and names as declared, every arm, mute
                                            and solo flag 0 (the verifier's own AX reading, D1)
                "mcu_upper_row_is_baseline" the MCU LCD upper row equals the one read when the
                                            fixture was first opened in this locale: the bank is
                                            home (the product's reading; nothing else reads the LCD)

A gate reading is {"declared": {"track_count", "names"}, "fingerprint": {"track_count", "names",
"flags": [{"arm", "mute", "solo"}, ...]}, "upper_row": {"readable", "value" | "cause"},
"passing_message"?: {"readable", "value" | "cause", "row"}}. `declared` travels with the reading, so
a recorded reading says what it was compared with. This module reads nothing itself and imports no
live code: check-spec and the engine can load it anywhere.

THE PASSING MESSAGE. After a record-enable press Logic writes its own name for the control across
the MCU upper row for a few seconds, from the pressed strip on, then puts the strips back: the
value of `Record Enable` in Logic.framework's Localizable.strings for the locale, with its
diacritics dropped (an accented e shows as a plain e). The live lifecycle puts that
string, read from the installed Logic, into `passing_message`; nothing here names it. A row that
shows it is not off home and not home: the runner reads the gate again until the message is gone,
up to a stated bound (runner.PASSING_WAIT_S), and a row still showing it after the bound is a
named problem, never a pass. A reading without a readable `passing_message` recognises nothing and
is judged against the baseline as before.
"""

import unicodedata

SETUPS = {
    "lpm-locale-campaign-19": {
        "live": "locale_campaign_19",
        "server_env": {"LOGIC_PRO_MCP_ARM_KEYCODE": "not-a-keycode"},
        "ready": "mcu",
        "gate": ["fingerprint", "mcu_upper_row_is_baseline"],
    },
    # The self-test's spec fixtures (fixtures/spec-*.json). Only FakeLifecycle drives them.
    "selftest-two-tracks": {
        "live": None,
        "server_env": {"LPM_VERIFY_SELFTEST_ENV": "declared-in-setups"},
        "ready": None,
        "gate": ["fingerprint", "mcu_upper_row_is_baseline"],
    },
    "selftest-canon": {"live": None, "server_env": {}, "ready": None, "gate": ["fingerprint"]},
    "selftest-every-operator": {"live": None, "server_env": {}, "ready": None, "gate": ["fingerprint"]},
}

GATES = ("fingerprint", "mcu_upper_row_is_baseline")
FLAG_WORDS = {"arm": "armed", "mute": "muted", "solo": "soloed"}


def setup_problems(fixture) -> list:
    """Why a spec's fixture is not one the runner knows; empty when it is."""
    ident = fixture.get("id") if isinstance(fixture, dict) else None
    if ident in SETUPS:
        return []
    return [f"fixture {ident!r} is not in the fixture registry (setups.SETUPS: "
            f"{', '.join(sorted(SETUPS))}); declare it there before a spec can name it"]


def declaration(ident: str) -> dict:
    """The registry's entry for `ident`, with its id, as the runner and the lifecycle are given it."""
    entry = SETUPS[ident]
    return {"id": ident, "live": entry["live"], "server_env": dict(entry["server_env"]),
            "ready": entry["ready"], "gate": list(entry["gate"])}


def _fingerprint_problems(reading: dict) -> list:
    fingerprint = reading.get("fingerprint") or {}
    declared = reading.get("declared") or {}
    if fingerprint.get("track_count") is None:
        return [f"the fixture could not be read: {reading.get('cause') or 'no fingerprint'}"]
    if fingerprint["track_count"] != declared.get("track_count"):
        return [f"{fingerprint['track_count']} tracks, declared {declared.get('track_count')}"]
    out = []
    for i, (name, wanted) in enumerate(zip(fingerprint.get("names") or [], declared.get("names") or [])):
        if name != wanted:
            out.append(f"track {i} is named {name!r}, declared {wanted!r}")
    flags = fingerprint.get("flags")
    if not isinstance(flags, list) or len(flags) != fingerprint["track_count"]:
        return out + ["the flags were not read for every track"]
    for i, row in enumerate(flags):
        for flag, word in FLAG_WORDS.items():
            value = row.get(flag) if isinstance(row, dict) else None
            if value is None:
                out.append(f"track {i} {flag} unreadable")
            elif value != 0:
                out.append(f"track {i} {word}")
    return out


def lcd_text(text: str) -> str:
    """`text` as the MCU LCD shows it: compatibility-decomposed, its combining marks dropped."""
    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))


def passing_message(reading: dict):
    """The passing message the reading carries, as the LCD shows it; None when it carries none."""
    message = (reading or {}).get("passing_message") or {}
    value = message.get("value") if message.get("readable") else None
    return lcd_text(value) if isinstance(value, str) and value.strip() else None


def shows_passing_message(reading: dict) -> bool:
    """Whether the reading's MCU upper row shows the passing message it carries."""
    row = (reading or {}).get("upper_row") or {}
    message = passing_message(reading)
    return bool(message and row.get("readable") and isinstance(row.get("value"), str)
                and message in row["value"])


def _upper_row_problems(reading: dict, baseline: dict) -> list:
    row = reading.get("upper_row") or {}
    base = (baseline or {}).get("upper_row") or {}
    if not row.get("readable"):
        return [f"the MCU upper row could not be read: {row.get('cause')}"]
    if not base.get("readable"):
        return [f"the baseline MCU upper row was not read: {base.get('cause')}"]
    if shows_passing_message(baseline):
        return [f"the baseline MCU upper row shows Logic's passing message "
                f"{passing_message(baseline)!r}: {base.get('value')!r}"]
    if shows_passing_message(reading):
        return [f"the MCU upper row still shows Logic's passing message "
                f"{passing_message(reading)!r}: {row.get('value')!r}"]
    if row.get("value") != base.get("value"):
        return [f"the MCU bank is off home: upper row {row.get('value')!r}, "
                f"baseline {base.get('value')!r}"]
    return []


def gate_problems(decl: dict, reading: dict, baseline: dict) -> list:
    """Why the fixture is not as declared right now, one named problem each; empty when it is."""
    out = [f"unknown gate {g!r}" for g in decl["gate"] if g not in GATES]
    if "fingerprint" in decl["gate"]:
        out += _fingerprint_problems(reading)
    if "mcu_upper_row_is_baseline" in decl["gate"]:
        out += _upper_row_problems(reading, baseline)
    return out
