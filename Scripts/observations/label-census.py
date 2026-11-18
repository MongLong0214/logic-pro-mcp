#!/usr/bin/env python3
"""A census of the Logic that is running, for ONE locale, filed as observation records.

    label-census.py plan   [LOCALE] [--json]          what a census can and cannot reach (offline)
    label-census.py run    LOCALE   [--write]         read the running Logic, file records
    label-census.py ingest LOCALE CENSUS.json [--write]   the same from a census already taken

READ-ONLY, and checked as such. The probe it drives (`locale-census.swift`) reads the menu bar, every
menu under it (AX reads them without opening them) and the main window's tree. It presses nothing,
opens nothing, selects nothing and writes nothing to the project, and this script adds no other path
to Logic: it never calls osascript or System Events (a unit test reads this file's source to keep
that true), it does not switch Logic's language (the operator does, before running it) and it does
not quit or relaunch Logic. Logic must already be running, in LOCALE.

WHAT IT EMITS. The existing observation records, through `locale_campaign_records.py` -- one per
surface, each citing the census as its evidence file -- with a `host` block carrying the Logic
`version` and `build` the probe read from the application's own Info.plist. A census whose host cannot
name both is refused before anything is filed, and the locale is PROVED rather than assumed: the
probe names four languages by their Edit menu; for the other six this script scores the menu bar
against Apple's own corpus for LOCALE and refuses unless LOCALE is the unique best reading.

WHAT IT CANNOT REACH. `plan` classifies every label by what the ledger already knows about where it
lives, with the reason, so "every label whose surface can be reached read-only" is a list and not a
claim:

    read_only         a navigation-free census record has already sighted it
    candidate         never sighted; its name and role put it on the menu bar or main window, which
                      the census reads. The first census decides, and a miss is reported, not hidden
    needs_navigation  its surface exists only after an action opens something -- a sheet, a dialog, a
                      popup, a plug-in or editor window -- which is a write or a modal, and a
                      read-only census must not make it. The reason names the record or the
                      property of the label that says so
    retired           excused; no element to read

A census that cannot classify a main-window row into a taxonomy surface (`locale_campaign_records.
classify` knows the path markers of ko-KR, ja-JP, de-DE and en-US only) files it nowhere and counts it
in the record's `limits`. Those counts are printed per run so the gap is visible, and the markers it
needs are read off the first census in that language, never guessed.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PROBE = os.path.join(HERE, "locale-census.swift")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module




def _read_census(path):
    """A census document from `path`: JSON Lines (current) or the older pretty-printed JSON."""
    spec = importlib.util.spec_from_file_location(
        "census_evidence_for_tool", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                 "census_evidence.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load(path)

def _labels():
    return _load("locale_labels_for_census", os.path.join(REPO, "Scripts", "locale_labels.py"))


def _records():
    return _load("locale_campaign_records_for_census", os.path.join(HERE, "locale_campaign_records.py"))


# --------------------------------------------------------------------------------------------------
# REACHABILITY: which labels a read-only census can reach, and why the others cannot.
# --------------------------------------------------------------------------------------------------
#: A name that says the label lives in something an action opens. Deliberately short and made of whole
#: words from the ledger's own naming, not a guess at every label: a label matching none of them and
#: sighted nowhere is a `candidate`, which the census then confirms or refutes. `Popup` alone is NOT here:
#: the label or value of a popup BUTTON is drawn on the main window and read without opening anything;
#: only what lives inside the popup (`Submenu`) needs it open. The arrange window's own title is a row of
#: the main-window walk, so `arrange*WindowTitle*` is exempt from the window-title rule.
OPENED_BY_AN_ACTION = re.compile(
    r"(WindowTitle|SheetTitle|DialogTitle|Sheet|Dialog|Modal|Confirm|SavePanel|ImportPanel|"
    r"ExportPanel|PanelTitle|Alert|Prompt|Chooser|Submenu|OkButton|CancelButton)")
#: Roles that only exist inside something opened.
OPENED_ROLES = {"AXSheet", "AXDialog", "AXSystemDialog", "AXPopover", "AXDrawer"}
#: What a record's own `method` says when it reached the element by acting on Logic.
ACTED_ON_LOGIC = re.compile(
    r"\b(opened|opening|pressed|press|driven|clicked|invoked|navigat\w*|raised|presented|"
    r"dialog|sheet|popup|pop-up|modal|inserted|created|added)\b", re.I)


def _record_facts(obs_dir, record_id, cache):
    if record_id not in cache:
        try:
            with open(os.path.join(obs_dir, f"{record_id}.json"), encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            doc = {}
        method = str(doc.get("method") or "").strip()
        cache[record_id] = {
            "surface": doc.get("surface"),
            "method": method,
            "navigation_free": record_id.endswith("-census") and method.startswith("Read, never actuated"),
        }
    return cache[record_id]


def reachability(doc, obs_dir):
    """`{label: {"class", "reason"}}` for every label in the ledger document.

    Derived from the ledger and its records, never from this script's opinion of a label: a label is
    `read_only` because a record whose own `method` says it was read without actuating anything
    sighted it, and `needs_navigation` because the only record that saw it says how it was reached.
    """
    cache = {}
    out = {}
    for name, entry in sorted((doc.get("labels") or {}).items()):
        retired = ((entry.get("retired") or {}).get("reason") or "").strip()
        if retired:
            out[name] = {"class": "retired", "reason": retired}
            continue
        cited = sorted({b.get("record") for b in (entry.get("provenance") or {}).values()
                        if isinstance(b, dict) and b.get("record")}
                       | {r for r in (entry.get("coverage_records") or {}).values() if r})
        facts = [(rid, _record_facts(obs_dir, rid, cache)) for rid in cited]
        census = [rid for rid, f in facts if f["navigation_free"]]
        if census:
            out[name] = {"class": "read_only",
                         "reason": f"sighted by the navigation-free census {census[0]}"}
            continue
        if facts:
            rid, f = facts[0]
            acted = ACTED_ON_LOGIC.search(f["method"])
            if acted:
                out[name] = {"class": "needs_navigation",
                             "reason": (f"its only evidence is {rid} (surface {f['surface']}), whose own "
                                        f"method says it acted on Logic ({acted.group(0)!r}): "
                                        f"{f['method'][:140]}")}
                continue
            out[name] = {"class": "candidate",
                         "reason": (f"its evidence so far is {rid}, which is not a navigation-free census "
                                    f"but states no action on Logic; the main-window census may reach it")}
            continue
        hit = None if name.startswith("arrange") else OPENED_BY_AN_ACTION.search(name)
        opened = [r for r in (entry.get("roles") or []) if r in OPENED_ROLES]
        if hit or opened:
            out[name] = {"class": "needs_navigation",
                         "reason": (f"never sighted, and its {'name carries ' + repr(hit.group(1)) if hit else 'role is ' + opened[0]} "
                                    f"-- it exists only inside a sheet, dialog, popup or window that an "
                                    f"action opens, which is a write or a modal")}
            continue
        out[name] = {"class": "candidate",
                     "reason": "never sighted anywhere; nothing in its name or role puts it behind an "
                               "action, so the menu bar and main-window census is where it would show"}
    return out


def plan(doc, obs_dir):
    """The coverage lists: labels a read-only census can reach, and labels that need a write or modal."""
    classes = reachability(doc, obs_dir)
    grouped = {"read_only": [], "candidate": [], "needs_navigation": [], "retired": []}
    for name, verdict in classes.items():
        grouped[verdict["class"]].append({"label": name, "reason": verdict["reason"]})
    return grouped


# --------------------------------------------------------------------------------------------------
# LOCALE: proved from the menu bar, never assumed.
# --------------------------------------------------------------------------------------------------
def menu_bar_scores(menu_bar, locales, labels_mod):
    """`{locale: how many of the bar's menu titles Apple's corpus ships in that locale}`, up to case."""
    canon = labels_mod._load_canon()
    if canon is None:
        return {}
    manifest = labels_mod._CANON_CACHE.get("manifest") or {}
    titles = [t for t in menu_bar if t]
    scores = {}
    for locale in locales:
        code = labels_mod._locale_code(locale)
        sources = [name for name, block in (manifest.get("sources") or {}).items()
                   if code in (block.get("locales") or [])]
        scores[locale] = sum(1 for t in titles
                             if any(canon.ships_up_to_case(src, code, t) for src in sources))
    return scores


def resolve_locale(census, requested, labels_mod):
    """`(locale, why)`; `locale` is None when the census does not prove the requested one.

    The probe's own answer is honoured when it gives one, and must equal the request. When it says
    `unknown` (six of the ten) the menu bar is scored against every supported locale's corpus and the
    request must be the UNIQUE best, with at least three titles matched -- a tie, or a weak match, is
    an inconclusive reading and refuses.
    """
    said = (census.get("host") or {}).get("locale")
    if said and said != "unknown":
        return (requested, "the probe named it from the Edit menu") if said == requested else (
            None, f"the running Logic reads as {said}, not {requested}")
    scores = menu_bar_scores(census.get("menu_bar") or [], labels_mod.SUPPORTED_LOCALES, labels_mod)
    if not scores:
        return None, "the probe could not name the locale and no canon is available to prove it"
    best = max(scores.values())
    leaders = [loc for loc, n in scores.items() if n == best]
    if leaders != [requested] or best < 3:
        return None, (f"the menu bar does not prove {requested}: Apple's corpus matches "
                      f"{ {k: v for k, v in sorted(scores.items(), key=lambda kv: -kv[1])[:4]} }")
    return requested, f"{best} menu titles match Apple's {requested} corpus and no other locale's"


# --------------------------------------------------------------------------------------------------
# FILING
# --------------------------------------------------------------------------------------------------
def _run_confirm(records_mod, repo, locale, date, kind="navigation-free"):
    """Run the `logic_canon.py confirm` command a refused census left, and report whether it exited 0.

    The refusal names strings whose 32-bit prefix is in a corpus and whose string comparison is not
    pinned yet; `confirm` reads the installed Logic's files (it never drives Logic) and pins them in
    docs/canon/ledger/presence.tsv. A runner used to have to copy that command out of the message.
    """
    day = date or __import__("datetime").date.today().isoformat()
    listing = records_mod.unconfirmed_path(repo, day, locale, kind)
    if not os.path.exists(listing):
        return False
    texts = [line.rstrip("\n") for line in open(listing, encoding="utf-8")]
    _path, command = records_mod.write_unconfirmed(repo, day, locale, [t for t in texts if t], kind)
    # Multi-line strings travel as ANSI-C quoted words, which only bash and zsh read.
    return subprocess.run(command, shell=True, executable="/bin/bash").returncode == 0


def ingest(locale, census, repo, write, date=None, labels_mod=None, records_mod=None, confirm=False):
    """File one census as observation records. Returns an exit code (0 filed, 2 refused).

    With `confirm`, a census refused for strings the canon cannot place is confirmed against the
    installed Logic and filed again, once. A refusal that survives that is returned as it is.
    """
    labels_mod = labels_mod or _labels()
    records_mod = records_mod or _records()
    host = dict(census.get("host") or {})
    why = records_mod.missing_release(host)
    if why:
        print(f"REFUSED: {why}. A record that does not name the Logic it was read on cannot be "
              f"counted by release.")
        return 2
    resolved, how = resolve_locale(census, locale, labels_mod)
    if resolved is None:
        print(f"REFUSED: {how}. Switch Logic to {locale} and relaunch it before the census.")
        return 2
    host["locale"] = resolved
    census = dict(census, host=host)
    declared = labels_mod.declared_logic(os.path.join(repo, "Sources", "LogicProMCP", "Accessibility",
                                                      "AXLocalePolicy.swift"))
    if declared and (host["version"], host["build"]) != (declared["version"], declared["build"]):
        print(f"NOTE: this Logic is {host['version']} ({host['build']}) and the declared current "
              f"release is {declared['version']} ({declared['build']}); the records are filed truthfully "
              f"and `locale-regenerate.py` will refuse them.")
    print(f"locale {resolved}: {how}")
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "census.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(census, handle, ensure_ascii=False)
        rc = records_mod.main(path, repo, write, date)
        if rc == 2 and confirm and write and _run_confirm(records_mod, repo, resolved, date,
                                                          census.get("kind") or "navigation-free"):
            print("confirmed the unplaced strings against the installed Logic; filing the census again")
            rc = records_mod.main(path, repo, write, date)
    if rc == 0:
        rows = census.get("census") or []
        unplaced = sum(1 for row in rows if records_mod.classify(row, resolved) is None
                       and not records_mod.is_window_frame(row))
        print(f"{unplaced} of {len(rows)} rows matched no surface rule for {resolved} and are in the "
              f"evidence file but under no record"
              + (" -- the area names come from docs/locale/census-areas.json; regenerate it with "
                 "Scripts/observations/census_areas.py --write and check the area is declared in "
                 "locale_campaign_records.AREA_RULES" if unplaced else ""))
    return rc


def capture():
    """Run the read-only probe against the running Logic and return its census, or raise."""
    with tempfile.TemporaryDirectory() as scratch:
        binary = os.path.join(scratch, "census")
        built = subprocess.run(["swiftc", "-O", PROBE, "-o", binary], capture_output=True, text=True)
        if built.returncode != 0:
            raise RuntimeError(f"cannot compile the census probe: {built.stderr.strip()[:300]}")
        ran = subprocess.run([binary], capture_output=True, text=True)
        if ran.returncode != 0:
            raise RuntimeError(f"census failed ({ran.returncode}) -- is Logic Pro running? "
                               f"{ran.stderr.strip()[:200]}")
        return json.loads(ran.stdout)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_plan = sub.add_parser("plan")
    p_plan.add_argument("locale", nargs="?")
    p_plan.add_argument("--json", action="store_true")
    p_run = sub.add_parser("run")
    p_run.add_argument("locale")
    p_run.add_argument("--write", action="store_true")
    p_ing = sub.add_parser("ingest")
    p_ing.add_argument("locale")
    p_ing.add_argument("census")
    p_ing.add_argument("--write", action="store_true")
    p_ing.add_argument("--confirm", action="store_true",
                       help="confirm strings the canon cannot place against the installed Logic, then file")
    p_run.add_argument("--confirm", action="store_true")
    args = parser.parse_args(argv)
    labels_mod = _labels()

    if args.cmd == "plan":
        doc = labels_mod.load_json()
        grouped = plan(doc, labels_mod.OBS_DIR)
        if args.json:
            json.dump(grouped, sys.stdout, ensure_ascii=False, indent=1)
            print()
            return 0
        for cls in ("read_only", "candidate", "needs_navigation", "retired"):
            print(f"{cls}: {len(grouped[cls])}")
        for item in grouped["needs_navigation"]:
            print(f"  needs_navigation  {item['label']}: {item['reason']}")
        return 0

    if args.cmd == "run":
        try:
            census = capture()
        except RuntimeError as exc:
            print(f"REFUSED: {exc}")
            return 2
    else:
        census = _read_census(args.census)
    return ingest(args.locale, census, REPO, args.write, labels_mod=labels_mod, confirm=args.confirm)


if __name__ == "__main__":
    sys.exit(main())
