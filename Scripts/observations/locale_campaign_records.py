#!/usr/bin/env python3
"""The offline half of a locale campaign: census -> evidence file -> one record per surface.

    python3 locale-campaign-records.py <census.json> <repo> [--write]

Reads a census produced by locale-census, classifies its rows into the surfaces SURFACES.md names,
writes the census under docs/observations/evidence/ and one observation record per surface that
cites it. The records are shaped to satisfy check-observation-records.py: a generated host block,
a runnable reverify command, non-empty observations and limits, and a conclusion whose numbers are
all present in the observations. Without --write it prints what it would write.

What is deliberately NOT here: switching Logic's language, relaunching it, or the fixture check.
Those are live steps in locale-campaign.sh; this half can be dry-run on any census.
"""
import datetime
import importlib.util
import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# WHICH SURFACE A CENSUS ROW BELONGS TO is decided by the main-window AREA its path passes through.
#
# The area names are Apple's strings, per locale, read from the row each comes from and committed in
# docs/locale/census-areas.json (`census_areas.py --write`): `Control Bar` / `Barra de controles` /
# `控制列`, and the Tracks area's four children composed from `%@ header`, `%@ contents`, `%@ legend`
# and `%@ time ruler` (`Cabecera de Pistas`, `En-tête Pistes`). This used to be a list of spellings
# typed after reading a census in en, ko, ja and de -- which left 526 to 537 rows unfiled in each of
# the other six locales, and would have left every future locale the same way.
#
# The AX tree has the same SHAPE in every locale (measured on all ten censuses of 2026-11-17/18), so
# the rules below are about the tree and only the names are localised:
#
#   AXToolbar|AXGroup[<Control Bar>] and its Transport Display      -> arrange.transport
#   AXGroup[<Mixer>] and a strip's AXLayoutArea[<Mixer>] in the
#       Inspector                                                   -> mixer.channel_strips
#   the rest of AXGroup[<Inspector>]                                -> inspector.channel_strip
#   AXGroup[<Library>]                                              -> library.patches
#   AXGroup[<Event>] and its Event / Marker / Tempo / Signature tabs -> editor.event_list
#   AXGroup[<Tracks>]:  its `contents` and `time ruler` children    -> arrange.regions
#                       its `header` and `legend` children          -> arrange.track_headers
#                       its own controls (snap, zoom, folders)      -> arrange.area_controls
#
# More specific first: a path passes through `AXGroup[Tracks]` on its way to `AXGroup[Tracks header]`,
# and through `AXToolbar[Control Bar]` on its way to `AXCheckBox[Mixer]`, which is a transport control.
# A row no rule places stays unplaced and is counted in its record's `limits`: the window itself, three
# bare buttons and one image have no area to be filed under.
#
# The probe names an element by its description cut to 28 characters (`locale-census.swift`), so an
# area whose name is longer is matched on its first 28.
PROBE_NAME_LIMIT = 28

#: (surface, areas whose bracketed name in the path files a row under it), most specific first.
AREA_RULES = [
    ("arrange.transport",     ("control_bar", "transport_display", "playhead_position")),
    ("arrange.regions",       ("contents", "time_ruler")),
    ("arrange.track_headers", ("header", "legend")),
    ("mixer.channel_strips",  ("mixer",)),
    ("library.patches",       ("library",)),
    ("editor.event_list",     ("event", "marker", "tempo", "signature")),
    ("inspector.channel_strip", ("inspector",)),
    ("arrange.area_controls", ("tracks",)),
]


def _areas():
    path = os.path.join(HERE, "census_areas.py")
    spec = importlib.util.spec_from_file_location("census_areas_for_records", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_AREAS = _areas()
_SEGMENT = re.compile(r"\[([^\]]*)\]$")
#: One path segment: a role, optionally with its bracketed name. The name may itself contain `/` (the
#: ja-JP tab `キー/拍子`, the de-DE tab `Taktart/Tonart`), so a path cannot be cut at every `/`; a
#: segment ends at the `]` that is followed by the next role or by the end of the path.
_PATH_SEGMENT = re.compile(r"(AX[A-Za-z]+)(?:\[(.*?)\](?=/AX|$))?")


def _fold(text):
    return text.replace("\u00a0", " ").casefold()


def _segments(path):
    """The bracketed names along a census path, folded: `AXGroup[Tracks]` -> `tracks`."""
    return [_fold(name) for _role, name in _PATH_SEGMENT.findall(path) if name]


def _names_for(locale):
    """`{area: [folded names]}` the committed table gives `locale`, or every locale's when it is None."""
    return {area: [_fold(n[:PROBE_NAME_LIMIT]) for n in found]
            for area, found in _AREAS.names(locale).items()}


def classify(row, locale=None):
    """The taxonomy surface a census row belongs to, or None when no rule places it."""
    if row["surface"] == "arrange.menus":
        return "arrange.menus"
    if row["surface"] not in ("arrange.window",):
        # A row read by a navigation census (nav-census.py) was read INSIDE a surface its step named, and
        # carries it. The area rules below are about where a row sits in the main window's tree.
        return row["surface"]
    names = _names_for(locale)
    segments = _segments(row["path"])
    for surface, areas in AREA_RULES:
        wanted = {name for area in areas for name in names.get(area, ())}
        if any(seg in wanted for seg in segments):
            return surface
    # A row outside every named area still says what it is in its help text. Kept for the censuses
    # taken before 13.0, where regions and headers sat under differently named containers.
    help_ = row.get("help") or ""
    if "리전" in help_ or "region" in help_.lower():
        return "arrange.regions"
    if ("트랙 헤더" in help_ or "track header" in help_.lower()
            or "spur-header" in help_.lower()):
        return "arrange.track_headers"
    return None


def _module(name):
    """A sibling of this directory's parent: `Scripts/<name>.py`, loaded by path."""
    spec = importlib.util.spec_from_file_location(
        f"{name}_for_records", os.path.join(os.path.dirname(HERE), f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def is_window_frame(row):
    """Whether a row sits at the window's own level: its title, close/minimise/zoom buttons, proxy icon.

    AppKit draws these (and two unnamed containers hold the areas), they sit directly under `AXWindow`
    with no area between, and the only Logic content they carry is the project name. No surface is true
    of them, so they are counted as window-level rows in a record's `limits` instead of being filed or
    being lumped in with rows a rule failed to place.
    """
    found = _PATH_SEGMENT.findall(row["path"])
    return (bool(found) and found[0][0] == "AXWindow" and len(found) <= 3
            and not any(name for _role, name in found[1:]))


def missing_release(host):
    """Why this host block cannot say which Logic the census was read on, or None when it can.

    A record that does not name its Logic version AND build is a reading of an unknown release, and the
    ledger counts a reading by the release it describes. Refused here, at the source, rather than filed
    and caught later: `?` is what the probe writes when it cannot read the application's Info.plist.
    """
    for axis in ("version", "build"):
        value = str((host or {}).get(axis) or "").strip()
        if value in ("", "?", "unknown"):
            return f"the census host carries no Logic {axis} ({value or 'empty'!r})"
    return None


METHOD_NAVIGATED = (
    "Navigated and restored. For each surface the plan names, one menu item or one element was pressed "
    "(found by a label set's own strings, a menu identifier or a key equivalent -- never by a coordinate), "
    "the window or sheet or menu that appeared was read to depth 10, and it was closed through its own "
    "cancel or close button. The window set and the project's modification time were read before and after "
    "each step and had to be equal. Each element with any string became one row of the evidence file."
)

# --------------------------------------------------------------------------------------------------
# THE CANON AXIS
# --------------------------------------------------------------------------------------------------
# A record joining the tree states facts about Logic, so `check-canon-citations.py` wants each of them
# CITED to Apple's bytes or PROVED absent from them (docs/canon/README.md). A census record states
# nothing but strings, so the generator accounts for every distinct string it files:
#
#   ships        a whole value of some pinned corpus      -> a `logic-canon://<source>/<locale>#value`
#                                                            citation carrying the string verbatim
#   absent       a value of no corpus and no near miss    -> one `canon_absent` proof over every corpus
#                                                            the manifest pins (project content, numbers)
#   near miss    absent as bytes, but a shipped label     -> filed under neither: a proof would be
#                folds to it (a colon, an ellipsis)          refused, and the shipped spelling is not
#                                                            something this census read. Named in `limits`
#   unconfirmed  its 32-bit prefix is in a corpus and no  -> REFUSED. Whether it ships is a string
#                string comparison is pinned                 comparison on a machine with Logic, and the
#                                                            generator does not guess it
#
# The citations are pinned by `Scripts/logic_canon.py build`, which reads the citations out of the
# records, and the unconfirmed ones are settled by `logic_canon.py confirm --stdin`. Neither runs here.

def _load_canon():
    path = os.path.join(os.path.dirname(os.path.dirname(HERE)), "Scripts", "logic_canon.py")
    spec = importlib.util.spec_from_file_location("logic_canon_for_census_records", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclass-style modules want to find themselves
    spec.loader.exec_module(module)
    return module


def _locale_preference(host_locale):
    """Corpus locales to cite from, best first, for a census taken in `host_locale`."""
    full = host_locale.replace("-", "_")
    return [full, full.split("_")[0], "en", "-"]


def account_for_strings(strings, host_locale, canon):
    """Sort every string into citations, absences, near misses and unconfirmed ones.

    Returns `(citations, absent, near, unconfirmed, corpora)`. `citations` is `[(ref, string)]` in
    string order. Everything is decided from the committed canon (`canon.presence`), so it runs with
    no Logic; a string the committed canon cannot decide comes back in `unconfirmed`.
    """
    manifest = canon.load_manifest()
    corpora = sorted((source, locale) for source, block in (manifest.get("sources") or {}).items()
                     for locale in (block.get("locales") or []))
    prefer = _locale_preference(host_locale)
    citations, absent, near, unconfirmed = [], [], [], []
    for text in strings:
        # An ASCII string is cited from English: the host locale's file may hold it only as the
        # untranslated English copy, which `check-canon-citations` refuses as "not localized".
        order = (["en"] + [p for p in prefer if p != "en"]) if text.isascii() else prefer
        rank = {locale: i for i, locale in enumerate(order)}
        verdicts = [(source, locale, canon.presence(source, locale, text)) for source, locale in corpora]
        shipped = [(rank.get(locale, len(order)), locale, source)
                   for source, locale, verdict in verdicts if verdict == canon.SHIPS]
        if shipped:
            _rank, locale, source = min(shipped)
            # Joined, not one f-string: `build` scans every file under Scripts/ for the scheme, and a
            # braced scheme literal here is read as a malformed citation.
            citations.append(("logic-canon://" + f"{source}/{locale}#value", text))
        elif any(verdict == canon.UNCONFIRMED for _s, _l, verdict in verdicts):
            unconfirmed.append(text)
        elif any(canon.differs_only_by_decoration(source, locale, text) for source, locale in corpora):
            near.append(text)
        else:
            absent.append(text)
    return citations, absent, near, unconfirmed, corpora


def canon_blocks(strings, host_locale, canon):
    """`(fields, near, unconfirmed)`: the record keys that carry the canon axis, ready to merge."""
    citations, absent, near, unconfirmed, corpora = account_for_strings(strings, host_locale, canon)
    fields = {"canon_groups": _module("canon_groups").group([
        {"ref": ref, "value": text,
         "used_for": "a label this surface exposes to AX, read verbatim from the census; cited so the "
                     "string is Apple's and not one that was typed",
         "binding": {"kind": "record"}}
        for ref, text in citations])}
    if absent:
        fields["canon_absent"] = [{
            "claim": f"{len(absent)} strings this surface exposes are a whole value of no corpus the "
                     f"canon pins, and no shipped label folds to them",
            "strings": absent,
            "searched": [{"source": source, "locale": locale} for source, locale in corpora],
            "why_runtime": "Apple's bytes hold none of them, so the only route to each is the census "
                           "reading itself: they are project content, numbers and runtime text",
        }]
    return fields, near, unconfirmed


def unconfirmed_path(repo, date, locale, kind="navigation-free"):
    """Where a refused census leaves the strings it could not place: beside the census it would file.

    Deterministic, so the operator (or a rule-following runner) can run the printed command, and the
    next run of the same census on the same day finds and replaces the same file.
    """
    return os.path.join(repo, "docs", "observations", "evidence",
                        f"{date}-{locale}-{kind}.unconfirmed.txt")


def write_unconfirmed(repo, date, locale, texts, kind="navigation-free"):
    """Write the unplaced strings for `logic_canon.py confirm --stdin`; return `(path, command)`.

    `confirm --stdin` reads one string per line, so a string carrying a line break cannot travel
    through the file: it is passed as a quoted argument on the same command instead, which `confirm`
    also accepts. The command names absolute paths so it runs from any directory.
    """
    path = unconfirmed_path(repo, date, locale, kind)
    one_line = sorted({t for t in texts if "\n" not in t and "\r" not in t})
    multi_line = sorted({t for t in texts if "\n" in t or "\r" in t})
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.writelines(f"{t}\n" for t in one_line)
    tool = os.path.join(repo, "Scripts", "logic_canon.py")
    command = " ".join(["python3", shlex.quote(tool), "confirm", "--stdin",
                        *(_one_line_quote(t) for t in multi_line), "<", shlex.quote(path)])
    return path, command


def _one_line_quote(text):
    """`text` as one shell word on ONE line: ANSI-C `$'...'` quoting (bash, zsh, macOS /bin/sh).

    `shlex.quote` keeps a line break literal inside single quotes, which is valid shell but prints the
    command over two lines, and a runner copying the printed line would run half of it.
    """
    escaped = (text.replace("\\", "\\\\").replace("'", "\\'")
               .replace("\n", "\\n").replace("\r", "\\r"))
    return f"$'{escaped}'"


def main(census_path, repo, write, date=None, canon=None):
    census = json.load(open(census_path, encoding="utf-8"))
    host = census["host"]
    locale = host["locale"]
    if locale == "unknown":
        print("census locale is unknown — refusing to file records that cannot say what they are true of")
        return 2
    why = missing_release(host)
    if why:
        print(f"{why} — refusing to file records that cannot say which Logic they are true of")
        return 2
    date = date or datetime.date.today().isoformat()
    obs_dir = os.path.join(repo, "docs", "observations")
    #: `navigation-free` (menus and the main window, read without pressing anything) or `navigation`
    #: (surfaces opened by nav-census.py, read, and closed again). The kind names the evidence file, the
    #: record ids, the method the record states and the command that re-reads it.
    kind = census.get("kind") or "navigation-free"
    ev_rel = f"evidence/{date}-{locale}-{kind}.census.jsonl"
    ev_path = os.path.join(obs_dir, ev_rel)

    buckets, unclassified, frame = {}, 0, 0
    for row in census["census"]:
        s = classify(row, locale)
        if s is None:
            if is_window_frame(row):
                frame += 1
            else:
                unclassified += 1
            continue
        buckets.setdefault(s, []).append(row)

    canon = canon or _load_canon()
    records = {}
    refused = []
    for surface, rows in sorted(buckets.items()):
        rid = f"{date}-{locale}-{surface.replace('.', '-')}-{'navigated-' if kind == 'navigation' else ''}census"
        strings = sorted({v for r in rows for k in ("title", "description", "help", "value") if (v := r.get(k))})
        idents = sorted({r["identifier"] for r in rows if r.get("identifier")})
        canon_fields, near, unconfirmed = canon_blocks(strings, locale, canon)
        if unconfirmed:
            refused.append((rid, unconfirmed))
        records[rid] = {
            "id": rid, "date": date, "schema": 3,
            "subject": f"Every string the {surface} surface exposes to AX in {locale}",
            "question": f"What labels does Logic show on {surface} in {locale}, and on which elements?",
            "verdict": "works",
            "issues": [768, 778],
            "surface": surface,
            "host": host,
            "reverify": {
                "kind": "script",
                "command": (f"Scripts/observations/nav-census.py {locale} --compare" if kind == "navigation"
                            else f"Scripts/observations/locale-census.sh {locale}"),
                "expected": f"a census in {locale} whose {surface} rows carry the same {len(strings)} distinct strings; a differing set means Logic's labels moved and every provenance citing this record wants re-reading",
                "cost": "~1 min with Logic open on the fixture project in that locale",
            },
            "depends": ["Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift"],
            "evidence": [ev_rel],
            "method": (
                METHOD_NAVIGATED if kind == "navigation" else
                "Read, never actuated. The menu bar and every menu were walked without opening them; "
                "the main window was walked to depth 8. Each element with any string became one row of "
                "the evidence file; rows were assigned to this surface by what their path or help text "
                "passes through, and rows no rule could place are counted in limits rather than filed."
            ),
            "observations": [
                {"what": f"rows on {surface}", "rows": len(rows),
                 "distinct_strings": len(strings), "distinct_identifiers": len(idents)},
                {"what": "the strings, verbatim", "strings": strings},
                {"what": "identifiers seen", "identifiers": idents},
            ],
            "conclusion": (
                f"On this host in {locale}, {surface} exposes {len(rows)} elements carrying "
                f"{len(strings)} distinct strings. Every string is in the evidence file verbatim, which "
                f"is what lets a label variant cite this record: the guard requires the string to occur "
                f"in the observations or evidence, and here it does or it does not."
            ),
            "limits": ([
                "Opened by one menu press or one element press each, read, and closed through the "
                "surface's own cancel or close button; no OK, Save, Create, Import, Export or Delete was "
                "pressed and no text was typed. The window set and the project's modification time read "
                "the same before and after every step (nav-census.py refuses to go on otherwise).",
                "Only the surfaces nav-plan.json names were opened: a surface not in the plan is not "
                "measured by this record.",
            ] if kind == "navigation" else [
                "Navigation-free surfaces only: nothing behind a menu press or a button was opened, so "
                "this says nothing about the mixer, plug-in editors or the editors.",
            ]) + [
                (f"{frame} window-level rows (the title bar, its close/minimise/zoom buttons and the "
                 f"unnamed containers directly under the window) belong to no area and are filed under no "
                 f"record; {unclassified} further window rows matched no area rule. All are in the "
                 "evidence file.") if kind != "navigation" else "Every row read is filed under the surface its step named.",
                "One project, one host, one build. A label that depends on project content — a track "
                "name, a region name — is a reading of this fixture, not of Logic.",
            ],
            "supersedes": None,
            **canon_fields,
        }
        if near:
            records[rid]["limits"].append(
                f"{len(near)} strings are neither cited nor proved absent: each is absent from Apple's "
                f"corpora as bytes and a shipped label folds to it (a colon, an ellipsis, a case), so "
                f"the spelling Logic ships is not something this census read: "
                + "; ".join(near))

    if refused:
        for rid, texts in refused:
            print(f"{rid}: {len(texts)} string(s) the committed canon cannot place")
        path, command = write_unconfirmed(repo, date, locale, [t for _rid, texts in refused for t in texts], kind)
        print("REFUSED: a string whose 32-bit prefix is in a corpus is neither shipped nor absent until a "
              f"string comparison is pinned. The unplaced strings are in {path}. On a machine with "
              f"Logic, read-only for Logic (it pins docs/canon/ledger/presence.tsv), run:\n"
              f"  {command}\n"
              "then file the records again. No record or evidence was written.")
        return 2
    stale = unconfirmed_path(repo, date, locale, kind)
    if write and os.path.exists(stale):
        # Settled: the list a refused run left is now a claim about a canon that has moved on.
        os.remove(stale)
    print(f"census {locale} {host['version']} ({host['build']}): {sum(len(v) for v in buckets.values())} rows "
          f"in {len(buckets)} surfaces, {unclassified} unclassified (+{frame} window-level)")
    for rid, rec in records.items():
        print(f"  {rid}: {rec['observations'][0]['rows']} rows, {rec['observations'][0]['distinct_strings']} strings")
    if not write:
        return 0
    os.makedirs(os.path.dirname(ev_path), exist_ok=True)
    # Compact on disk: the evidence one row per line (`census_evidence`), a record with every leaf on one
    # line (`compact_json`). Their BYTES are what a reading's `record_sha256` binds.
    with open(ev_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(_module("census_evidence").dumps(dict(census, kind=kind)))
    for rid, rec in records.items():
        with open(os.path.join(obs_dir, f"{rid}.json"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(_module("compact_json").dumps(rec, 2))
    print(f"wrote {ev_rel} and {len(records)} record(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2], "--write" in sys.argv))
