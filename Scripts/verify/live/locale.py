"""One locale switch for the ten locales Logic ships, confirmed by Apple's own row.

Consolidates the switch written separately at least six times (audit-A-report.md section 3):

- Scripts/livekit/live_993_plugin_root_menu_in_every_locale.py:88-302 -- the base: `osa`,
  `apple_string`, `language_setting`, `logic_running`, `window_names`, `blocking_counts`,
  `press_discard`, `press_default_button`, `dismiss_sheets`, `close_left_open_menus`,
  `unidentified_documents`, `quit_logic`, `launch`, `switch_to(lproj, force)`. It is the most
  complete: it refuses to quit over any document but the fixture (another may be an iCloud one,
  which no authority covers), closes left-open menus before quitting, and confirms the switch by
  the arrange window's title built from Apple's `Tracks` row.
- Scripts/livekit/probe_993_1004_nbsp_labels_as_drawn.py:214-260 and :482-492 -- the same shape
  with a fixed sleep after launch; that sleep is dropped here (every wait is `obs.wait_until`).
- live_883:262-300, live_519:132-180, live_876:217-253 -- `set_language`/`quit_logic`/`launch`
  variants with fewer guards; nothing of theirs is missing from the above.

The expected title suffix is never typed: it is Apple's `Tracks` row of Logic.framework's
Localizable.strings for the target lproj, parsed by Scripts/logic_canon.py, as live_993:97-101 does.

`apple_row()` is the one door to Apple's text for the rest of this package (probes resolve their
labels through it). A row is marked `same_as_en` when its value is byte-identical to English: for
it/pt/zh_TW QuickHelp that is Apple shipping English (canon D6/D1, logic_canon.py:98), so such a
row is not proof of a translation.
"""

import os
import re
import sys
import urllib.parse

from . import obs, screen

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(os.path.dirname(HERE))

LOCALES = ("de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh_CN", "zh_TW")
#: lproj -> the AppleLanguages code Logic is given (live_993:46-47).
CODES = {"de": "de", "en": "en", "es": "es", "fr": "fr", "it": "it", "ja": "ja", "ko": "ko",
         "pt": "pt-BR", "zh_CN": "zh-CN", "zh_TW": "zh-TW"}
RESTING = "ko"
APP = "/Applications/Logic Pro.app"
DOMAIN = "com.apple.logic10"
FIXTURE = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
LAUNCH_TIMEOUT_S = 150.0
QUIT_TIMEOUT_S = 20.0

SOURCES = {
    "strings:Logic": APP + "/Contents/Frameworks/Logic.framework/Versions/A/Resources/%s.lproj/"
                           "Localizable.strings",
    "strings:MAMixer": APP + "/Contents/Frameworks/MAMixer.framework/Resources/%s.lproj/"
                             "Localizable.strings",
    "quickhelp": APP + "/Contents/Resources/%s.lproj/QuickHelp.plist",
}


def _canon():
    if SCRIPTS not in sys.path:
        sys.path.insert(0, SCRIPTS)
    import logic_canon
    return logic_canon


_TABLES = {}


def _table(source, lproj):
    key = (source, lproj)
    if key not in _TABLES:
        canon = _canon()
        path = SOURCES[source] % lproj
        if source.startswith("strings:"):
            with open(path, "rb") as handle:
                _TABLES[key] = canon.parse_strings(handle.read(), path=path)
        else:
            _TABLES[key] = canon.load_plist(path)
    return _TABLES[key]


def apple_row(lproj, key, source="strings:Logic", field=None):
    """Apple's value for one row in one lproj, with the row named; unreadable if it is not there."""
    row = {"source": source, "lproj": lproj, "key": key, "field": field,
           "path": SOURCES.get(source, "?") % lproj if source in SOURCES else None}
    if source not in SOURCES:
        return obs.unreadable("unknown source", row=row)

    def value_in(lp):
        entry = _table(source, lp).get(key)
        if field is not None:
            entry = ((entry or {}).get("_LOCALIZABLE_") or {}).get(field) if isinstance(entry, dict) else None
        return entry

    try:
        value = value_in(lproj)
        english = value_in("en") if lproj != "en" else value
    except (OSError, ValueError, KeyError) as exc:
        return obs.unreadable(f"Apple's table could not be read: {exc!r}", row=row)
    except Exception as exc:  # noqa: BLE001 - logic_canon raises its own error types
        return obs.unreadable(f"Apple's table could not be parsed: {exc!r}", row=row)
    if not isinstance(value, str) or not value:
        return obs.unreadable("the row is not in Apple's table", row=row)
    return obs.readable(value, row=row, same_as_en=(lproj != "en" and value == english))


# ---------------------------------------------------------------------------------------------
# Logic, through System Events (live_993:104-281)
# ---------------------------------------------------------------------------------------------

def language_setting():
    raw = obs.run(["/usr/bin/defaults", "read", DOMAIN, "AppleLanguages"], 10)
    if raw["returncode"] != 0:
        return obs.unreadable("defaults read failed", raw=raw)
    return obs.readable(re.findall(r"[\w-]+", raw["stdout"]), raw=raw["stdout"])


def logic_running():
    pids = screen.logic_pids()
    if not pids["readable"]:
        return pids
    return obs.readable(bool(pids["value"]), pids=pids["value"])


def window_names():
    raw = obs.osascript('tell application "System Events" to tell process "Logic Pro" to '
                        'get name of every window')
    if raw["returncode"] != 0:
        return obs.unreadable("System Events did not list Logic's windows", raw=raw)
    text = (raw["stdout"] or "").strip()
    return obs.readable([part.strip() for part in text.split(", ")] if text else [])


def press_discard():
    """The dialog button that is neither default nor cancel, pressed by AX (live_993:135-155)."""
    return obs.osascript('''tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  set skip to {}
  try
    set end of skip to name of (value of attribute "AXDefaultButton" of d) as string
  end try
  try
    set end of skip to name of (value of attribute "AXCancelButton" of d) as string
  end try
  if (count of skip) is not 2 then return ""
  repeat with b in (every button of d)
    set n to name of b as string
    if n is not in skip then
      click b
      return n
    end if
  end repeat
  return ""
end tell''')


def press_default_button():
    """The default button of a dialog shown while the fixture opens (live_993:158-169)."""
    return obs.osascript('''tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  try
    set b to value of attribute "AXDefaultButton" of d
    set n to name of b as string
    click b
    return n
  end try
  return ""
end tell''')


def open_documents():
    """Every Logic window's AXDocument (live_993:219-246); unreadable when the list is cut short."""
    raw = obs.osascript('''tell application "System Events" to tell process "Logic Pro"
  set out to ""
  repeat with w in windows
    try
      set out to out & (value of attribute "AXDocument" of w as string) & linefeed
    end try
  end repeat
  return out & "lpm:end-of-documents"
end tell''')
    text = (raw.get("stdout") or "").strip()
    if raw["returncode"] != 0 or not text.endswith("lpm:end-of-documents"):
        return obs.unreadable("the document list did not complete", raw=raw)
    docs = []
    for line in text.splitlines()[:-1]:
        doc = line.strip()
        if not doc or doc == "missing value":
            continue
        path = (urllib.parse.unquote(urllib.parse.urlparse(doc).path)
                if doc.startswith("file:") else doc)
        docs.append({"raw": doc, "path": os.path.realpath(path.rstrip("/"))})
    return obs.readable(docs)


def others_than(fixture, docs_reading):
    """Documents that are not the fixture, or None when the list was not read."""
    if not docs_reading["readable"]:
        return None
    target = os.path.realpath(fixture)
    return [d for d in docs_reading["value"] if d["path"] != target]


def quit_logic(fixture=FIXTURE):
    """Quit Logic, answering Don't Save only for the fixture. Raw record of every step."""
    record = {"steps": []}
    running = logic_running()
    record["running_before"] = running
    if running.get("readable") and running["value"] is False:
        record["quit"] = True
        return record
    docs = open_documents()
    record["documents"] = docs
    others = others_than(fixture, docs)
    if others is None or others:
        record["quit"] = False
        record["cause"] = ("the open documents could not be read" if others is None else
                           "a document other than the fixture is open; not answering its save prompt")
        return record
    record["settle"] = screen.settle_to_clean(timeout_s=8.0)
    for attempt in range(4):
        sent = obs.osascript('tell application "Logic Pro" to quit', 8)
        record["steps"].append({"attempt": attempt, "quit_sent": sent})
        discards = []

        def gone_or_discard():
            state = logic_running()
            if state.get("readable") and state["value"] is False:
                return True
            pressed = press_discard()
            if (pressed.get("stdout") or "").strip():
                discards.append(pressed)
            return False

        waited = obs.wait_until(gone_or_discard, QUIT_TIMEOUT_S, interval_s=0.5)
        record["steps"][-1].update(discards=discards, wait={k: waited[k] for k in
                                                           ("timed_out", "elapsed_s", "polls")})
        if not waited["timed_out"]:
            record["quit"] = True
            return record
    after = logic_running()
    record["running_after"] = after
    record["quit"] = bool(after.get("readable") and after["value"] is False)
    return record


def launch(fixture, title, timeout_s=LAUNCH_TIMEOUT_S):
    """Open the fixture; wait (bounded) for `title` among Logic's windows. Raw record."""
    opened = obs.run(["/usr/bin/open", "-a", APP, fixture], 30)
    pressed = []

    def has_title():
        names = window_names()
        if names["readable"] and title in names["value"]:
            return names
        button = press_default_button()
        if (button.get("stdout") or "").strip():
            pressed.append(button)
        return None

    waited = obs.wait_until(has_title, timeout_s, interval_s=0.5)
    last_names = window_names()
    return {"open": opened, "title_expected": title, "timed_out": waited["timed_out"],
            "elapsed_s": waited["elapsed_s"], "polls": waited["polls"],
            "default_buttons_pressed": pressed, "window_names": last_names}


def expected_title(lproj, fixture=FIXTURE):
    """`<fixture name> - <Apple's Tracks row in lproj>`, with the row it came from."""
    suffix = apple_row(lproj, "Tracks")
    name = os.path.splitext(os.path.basename(fixture))[0]
    if not suffix["readable"]:
        return {**suffix, "fixture_name": name}
    return obs.readable(f"{name} - {suffix['value']}", suffix=suffix, fixture_name=name)


def reading(lproj, fixture=FIXTURE):
    """What says which language Logic is in right now: the setting and the window names."""
    return {"lproj": lproj, "code": CODES.get(lproj), "expected_title": expected_title(lproj, fixture),
            "language_setting": language_setting(), "window_names": window_names()}


def switch_to(lproj, fixture=FIXTURE, force=False):
    """Quit Logic, write AppleLanguages, relaunch the fixture; raw readings before and after.

    With `force` False and Logic already in `lproj` on the fixture (setting AND arrange title),
    nothing is driven and `switched` is False. Whether the switch HELD is the caller's predicate
    over `after` (see `in_locale`); this returns readings, not a verdict.
    """
    if lproj not in CODES:
        return {"lproj": lproj, "switched": False, "cause": "unknown lproj"}
    before = reading(lproj, fixture)
    record = {"lproj": lproj, "code": CODES[lproj], "fixture": fixture, "forced": force,
              "before": before}
    if not before["expected_title"]["readable"]:
        record.update(switched=False, cause="Apple's Tracks row did not resolve")
        return record
    title = before["expected_title"]["value"]
    if not force and in_locale(before):
        record.update(switched=False, after=before)
        return record
    record["quit"] = quit_logic(fixture)
    if not record["quit"].get("quit"):
        record.update(switched=False, cause="Logic did not quit", after=reading(lproj, fixture))
        return record
    record["write"] = obs.run(["/usr/bin/defaults", "write", DOMAIN, "AppleLanguages", "-array",
                               CODES[lproj]], 10)
    record["launch"] = launch(fixture, title)
    record["switched"] = True
    record["after"] = reading(lproj, fixture)
    return record


def in_locale(snapshot):
    """The predicate over a `reading()`: the setting leads with the code and the title is shown."""
    setting = snapshot.get("language_setting") or {}
    names = snapshot.get("window_names") or {}
    title = snapshot.get("expected_title") or {}
    return bool(setting.get("readable") and names.get("readable") and title.get("readable")
                and setting["value"][:1] == [snapshot.get("code")]
                and title["value"] in names["value"])


def restore_locale(lproj=RESTING, fixture=FIXTURE, force=False):
    """Put Logic back in `lproj` (Korean is the resting state), confirmed the same way."""
    return switch_to(lproj, fixture=fixture, force=force)
