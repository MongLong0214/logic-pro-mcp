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
                                            home (the product's reading; nothing else reads the LCD).
                                            The baseline itself must be home by independent
                                            evidence: each of its eight cells abbreviates the
                                            name of the track in the same slot of the first bank,
                                            as the baseline's own AX fingerprint names them
                                            (`home_problems`); a reading is never home only
                                            because it equals itself

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


#: The MCU LCD upper row: eight cells of seven characters, six of a strip's name and one separator,
#: each with its trailing spaces trimmed (Sources/LogicProMCP/Channels/MCUChannel.swift
#: `bankWindowStrips`, which pads or cuts a row to 56 characters first).
LCD_CELLS = 8
LCD_CELL_WIDTH = 7


def lcd_cells(row: str) -> list:
    """The eight cells of an MCU upper row, as MCUChannel.bankWindowStrips cuts them."""
    width = LCD_CELLS * LCD_CELL_WIDTH
    padded = row.ljust(width)[:width]
    return [padded[i:i + LCD_CELL_WIDTH].rstrip(" ") for i in range(0, width, LCD_CELL_WIDTH)]


def abbreviates(cell: str, name: str) -> bool:
    """Whether an LCD `cell` is Logic's six-character squeeze of the track `name`: whitespace gone,
    case folded, the same first letter, and every other letter of the cell found in the name in
    order. Logic drops letters rather than cutting ("Deluxe Classic" shows as `DelCls`, "Absolute
    Zero" as `AbsZer`); the rule is Scripts/livekit/live_862_bank_answers_from_the_redrawn_upper_row.py
    `abbreviates`, measured 2026-09-27, with the name taken as the LCD shows it (`lcd_text`)."""
    c = "".join(cell.split()).lower()
    n = "".join(lcd_text(name).split()).lower()
    if not c or not n or c[0] != n[0]:
        return False
    rest = iter(n[1:])
    return all(ch in rest for ch in c[1:])


def home_problems(reading: dict) -> list:
    """Why the reading's MCU upper row is not the first bank of the tracks its own AX fingerprint
    names (tracks 0-7): each cell must abbreviate the name in its slot, and a slot past the last
    track must be empty. Empty when it is home. A row, or names, that cannot be matched is not
    home: the verdict is never taken from the row alone."""
    row = (reading or {}).get("upper_row") or {}
    names = ((reading or {}).get("fingerprint") or {}).get("names")
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
        return [f"the baseline's AX track names were not read ({names!r}), so its MCU upper row "
                f"{row.get('value')!r} cannot be shown to be home"]
    first = names[:LCD_CELLS]
    cells = lcd_cells(row.get("value") or "")
    misses = [i for i, cell in enumerate(cells)
              if not (abbreviates(cell, first[i]) if i < len(first) else cell == "")]
    if misses:
        return [f"the baseline MCU upper row {row.get('value')!r} is not home: cell(s) "
                f"{', '.join(map(str, misses))} do not abbreviate the first bank's AX track names "
                f"{first!r}"]
    return []


def baseline_problems(decl: dict, baseline: dict) -> list:
    """Why a locale's baseline cannot stand for home, as the upper-row gate needs it; empty when it
    can, or when the declaration has no upper-row gate."""
    if "mcu_upper_row_is_baseline" not in decl["gate"]:
        return []
    base = (baseline or {}).get("upper_row") or {}
    if not base.get("readable"):
        return [f"the baseline MCU upper row was not read: {base.get('cause')}"]
    if shows_passing_message(baseline):
        return [f"the baseline MCU upper row shows Logic's passing message "
                f"{passing_message(baseline)!r}: {base.get('value')!r}"]
    return home_problems(baseline)


def _upper_row_problems(decl: dict, reading: dict, baseline: dict) -> list:
    row = reading.get("upper_row") or {}
    base = (baseline or {}).get("upper_row") or {}
    if not row.get("readable"):
        return [f"the MCU upper row could not be read: {row.get('cause')}"]
    unfit = baseline_problems(decl, baseline)
    if unfit:
        return unfit
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
        out += _upper_row_problems(decl, reading, baseline)
    return out
