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


#: One line per window: `doc<TAB>subrole<TAB>url`, `none<TAB>subrole` (AXDocument is missing
#: value), `absent<TAB>subrole` (no AXDocument attribute), or `error<TAB>subrole<TAB>n<TAB>message`.
#: The header says how many windows there are, and the end marker that the loop finished, so a
#: failed read can no longer vanish into a shorter list (PR #1033 review R1).
DOCUMENTS_SCRIPT = '''tell application "System Events" to tell process "Logic Pro"
  set ws to every window
  set out to "lpm:windows " & (count of ws) & linefeed
  repeat with w in ws
    set sr to "?"
    try
      set sr to (value of attribute "AXSubrole" of w) as string
    on error m number n
      set sr to "?error " & n
    end try
    try
      if exists attribute "AXDocument" of w then
        set v to value of attribute "AXDocument" of w
        if v is missing value then
          set out to out & "none" & tab & sr & linefeed
        else
          set out to out & "doc" & tab & sr & tab & (v as string) & linefeed
        end if
      else
        set out to out & "absent" & tab & sr & linefeed
      end if
    on error m number n
      set out to out & "error" & tab & sr & tab & n & tab & m & linefeed
    end try
  end repeat
  return out & "lpm:end-of-documents"
end tell'''
DOCUMENTS_END = "lpm:end-of-documents"
#: A standard window is a project window. One with no AXDocument is an untitled project, which
#: the old `missing value is a palette` rule let through (3753b7e6's Limit).
PROJECT_WINDOW_SUBROLE = "AXStandardWindow"


def _document_row(index, line):
    parts = line.split("\t")
    kind, subrole = parts[0], (parts[1] if len(parts) > 1 else None)
    row = {"index": index, "line": line, "subrole": subrole}
    if subrole is None or subrole.startswith("?"):
        return {**row, "outcome": "unreadable", "cause": "AXSubrole not read"}
    if kind == "doc" and len(parts) >= 3 and parts[2]:
        doc = "\t".join(parts[2:])
        path = (urllib.parse.unquote(urllib.parse.urlparse(doc).path)
                if doc.startswith("file:") else doc)
        return {**row, "outcome": "document", "raw": doc,
                "path": os.path.realpath(path.rstrip("/"))}
    if kind in ("none", "absent") and len(parts) == 2:
        if subrole == PROJECT_WINDOW_SUBROLE:
            return {**row, "outcome": "unidentified_document", "raw": line}
        return {**row, "outcome": "no_document"}
    if kind == "error":
        return {**row, "outcome": "unreadable", "cause": "AXDocument read failed"}
    return {**row, "outcome": "unreadable", "cause": "a line of no known shape"}


def parse_documents(stdout):
    """The DOCUMENTS_SCRIPT output -> readable [row per window] or unreadable.

    Unreadable when the header or end marker is missing or the rows are not exactly the counted
    windows. Each row's `outcome` is `document` (with `path`), `no_document`, `unidentified_document`
    (a project window with no AXDocument) or `unreadable` (with `cause`).
    """
    lines = (stdout or "").strip("\n").split("\n")
    header = re.fullmatch(r"lpm:windows (\d+)", lines[0].strip()) if lines else None
    if header is None or lines[-1].strip() != DOCUMENTS_END:
        return obs.unreadable("the window list has no header or did not complete", raw=stdout)
    body = lines[1:-1]
    if len(body) != int(header.group(1)):
        return obs.unreadable("the rows are not the counted windows", raw=stdout,
                              counted=int(header.group(1)), rows=len(body))
    return obs.readable([_document_row(i, line) for i, line in enumerate(body)], raw=stdout)


def open_documents():
    """Every Logic window's document read outcome (parse_documents); raw osascript kept."""
    raw = obs.osascript(DOCUMENTS_SCRIPT)
    if raw["returncode"] != 0:
        return obs.unreadable("System Events did not answer", raw=raw)
    reading = parse_documents(raw.get("stdout"))
    reading["osascript"] = raw
    return reading


def others_than(fixture, docs_reading):
    """Documents that are not the fixture (unidentified project windows included), or None when
    the list, or any window in it, was not read: an unread document is not an absent one."""
    if not docs_reading.get("readable"):
        return None
    rows = docs_reading["value"]
    if any(row["outcome"] == "unreadable" for row in rows):
        return None
    target = os.path.realpath(fixture)
    return [row for row in rows if row["outcome"] == "unidentified_document"
            or (row["outcome"] == "document" and row["path"] != target)]


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
        # Refused before any quit or save-prompt answer; the raw readings stay in the record.
        record["quit"] = False
        record["cause"] = ("a window's document could not be read" if others is None else
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
