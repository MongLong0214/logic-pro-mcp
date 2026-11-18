#!/usr/bin/env python3
"""The navigation census: how it finds a menu item, and that a step it cannot undo stops everything.

Nothing here touches Logic. `nav-census.py` takes the probe's two reads (the window set and the result of a
step) and the project's modification time as functions, so the way back is exercised with fakes:

    resolve    a step names a label, an identifier or a key equivalent; it resolves against the LOCALE's own menu
               rows, to exactly one path, or it is reported UNRESOLVED
    restore    a step whose window set differs afterwards, or whose project moved, stops the run and files nothing
    filing     the rows file as a `navigation` census under the surface their step named; evidence is JSON Lines

Each refusal is shown with a MUTANT: the source with the line that enforces it neutralised, run through the same
scenario, which must then go wrong.
"""
import importlib.util
import json
import os
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
OBS = HERE / "observations"
NAV = OBS / "nav-census.py"
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


def load(path, name, source=None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if source is None:
        spec.loader.exec_module(module)
    else:
        module.__file__ = str(path)
        exec(compile(source, str(path), "exec"), module.__dict__)
    return module


def mutated(old, new, name):
    text = NAV.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"mutant {name}: {old[:70]!r} occurs {text.count(old)} time(s), not once")
    return load(NAV, name, text.replace(old, new))


nav = load(NAV, "nav_under_test")
records = load(OBS / "locale_campaign_records.py", "nav_records")

ROWS = [
    {"surface": "arrange.menus", "role": "AXMenuItem", "title": "별도 저장…", "identifier": "globalMenuItemCall:",
     "path": "AXMenuBar/AXMenuBarItem[파일]/AXMenu/AXMenuItem[별도 저장…]"},
    {"surface": "arrange.menus", "role": "AXMenuItem", "title": "할당 편집…", "identifier": "showWindow:",
     "path": "AXMenuBar/AXMenuBarItem[Logic Pro]/AXMenu/AXMenuItem[키 명령]/AXMenu/AXMenuItem[할당 편집…]"},
    {"surface": "arrange.menus", "role": "AXMenuItem", "title": "MIDI 파일…", "identifier": None,
     "path": "AXMenuBar/AXMenuBarItem[파일]/AXMenu/AXMenuItem[가져오기]/AXMenu/AXMenuItem[MIDI 파일…]"},
    {"surface": "arrange.menus", "role": "AXMenuItem", "title": "MIDI 파일…", "identifier": None,
     "path": "AXMenuBar/AXMenuBarItem[파일]/AXMenu/AXMenuItem[내보내기]/AXMenu/AXMenuItem[MIDI 파일…]"},
]
CENSUS = {"census": ROWS, "host": {"locale": "ko-KR"}}
LABELS = {"labels": {"saveAsMenuItem": {"canonical": "Save As…", "variants": ["별도 저장…", "Speichern unter …"]},
                     "midiFileMenuItem": {"canonical": "MIDI File…", "variants": ["MIDI 파일…"]},
                     "importMenuItem": {"canonical": "Import", "variants": ["가져오기"]}}}

# ---- resolving ---------------------------------------------------------------------------------------
path, why = nav.resolve({"label": "saveAsMenuItem"}, CENSUS, LABELS)
case("a label resolves through the locale's own strings", path and path.endswith("AXMenuItem[별도 저장…]"), (path, why))
path, why = nav.resolve({"identifier": "showWindow:"}, CENSUS, LABELS)
case("a menu identifier resolves, and a no-break space in the path survives", path and "Logic Pro" in path, (path, why))
path, why = nav.resolve({"label": "midiFileMenuItem"}, CENSUS, LABELS)
case("a label that matches two menu items is NOT guessed", path is None and "2 menu items" in why, (path, why))
path, why = nav.resolve({"label": "midiFileMenuItem", "under": "importMenuItem"}, CENSUS, LABELS)
case("`under` names the parent menu and makes it one", path and "[가져오기]" in path, (path, why))
case("a label with no set is refused", nav.resolve({"label": "nope"}, CENSUS, LABELS)[0] is None)
case("an ellipsis spelt three dots is the same title", nav.fold("Save As...") == nav.fold("Save As…"))
spec, why = nav.open_spec({"id": "s", "surface": "x", "open": [{"label": "nope"}, {"shortcut": {"char": "N", "mods": 2}}]}, CENSUS, LABELS)
case("the next strategy is tried when one does not resolve", spec and spec["open"]["kind"] == "menu-shortcut", (spec, why))
spec, why = nav.open_spec({"id": "s", "surface": "x", "open": [{"label": "nope"}]}, CENSUS, LABELS)
case("no strategy resolving is UNRESOLVED, with the reason", spec is None and why, why)

# ---- the way back ------------------------------------------------------------------------------------
fixture = Path(tempfile.mkdtemp()) / "P.logicx"
(fixture / "Alternatives").mkdir(parents=True)
(fixture / "Alternatives/x").write_text("a", encoding="utf-8")


def fake_run(module, after_windows, touch, opened=True, probe_restored=True):
    """Run one step with fakes: `windows` answers `[before, after]` in turn; `touch` moves the project."""
    answers = [[{"title": "main"}], after_windows]
    module.windows = lambda _binary: answers.pop(0)

    def runner(_cmd, **_kw):
        if touch:
            (fixture / "Alternatives/x").write_text("changed", encoding="utf-8")
            os.utime(fixture / "Alternatives/x", None)
        body = {"opened": opened, "restored": probe_restored, "census": [{"surface": "s", "path": "p", "role": "r", "title": "t"}],
                "closed_by": ["AXCancelButton"]}
        return types.SimpleNamespace(stdout=json.dumps(body), stderr="", returncode=0)
    with tempfile.TemporaryDirectory() as scratch:
        return module.run_step("bin", {"surface": "s"}, scratch, str(fixture), runner)


good = fake_run(nav, [{"title": "main"}], touch=False)
case("a step that restores the windows and leaves the project alone is restored",
     good["restored"] and good["project_untouched"], good)
left = fake_run(nav, [{"title": "main"}, {"title": "sheet"}], touch=False)
case("a window left open is NOT restored", left["restored"] is False, left)
moved = fake_run(nav, [{"title": "main"}], touch=True)
case("a project whose modification time moved is flagged", moved["project_untouched"] is False, moved)
case("the probe's own `restored: false` is believed", fake_run(nav, [{"title": "main"}], False, probe_restored=False)["restored"] is False)

m = mutated('    result["restored"] = bool(result.get("restored")) and after_windows == before_windows\n',
            '    result["restored"] = bool(result.get("restored"))\n', "mut_nav_windows")
case("MUTANT: trusting the probe alone misses a window left open", fake_run(m, [{"title": "main"}, {"title": "sheet"}], False)["restored"] is True)
m = mutated('    result["project_untouched"] = after_mtime == before_mtime\n', '    result["project_untouched"] = True\n', "mut_nav_mtime")
case("MUTANT: ignoring the modification time misses a touched project", fake_run(m, [{"title": "main"}], True)["project_untouched"] is True)

# a run stops at the first step that was not undone, and keeps nothing from it
plan = {"steps": [{"id": "a", "surface": "s", "open": [{"shortcut": {"char": "A", "mods": 0}}]},
                  {"id": "b", "surface": "s", "open": [{"shortcut": {"char": "B", "mods": 0}}]}]}
calls = []


def stepper(module, results):
    seq = list(results)

    def one(_binary, spec, _scratch, _fixture=None, _runner=None):
        calls.append(spec["open"]["char"])
        return seq.pop(0)
    module.run_step = one


bad = {"census": [{"path": "x"}], "restored": False, "project_untouched": True, "opened": True}
fine = {"census": [{"path": "y"}], "restored": True, "project_untouched": True, "opened": True}
nav2 = load(NAV, "nav_run_a")
stepper(nav2, [bad, fine])
rows, reports, ok = nav2.run("ko-KR", plan, CENSUS, LABELS, "bin", "scratch", out=lambda _l: None)
case("an unrestored step stops the run: the second step never runs and no row is kept",
     ok is False and calls == ["A"] and rows == [] and reports[0]["status"] == "NOT RESTORED", (ok, calls, rows))
m = mutated('        if not (result["restored"] and result["project_untouched"]):\n', "        if False:\n", "mut_nav_stop")
calls.clear()
stepper(m, [bad, fine])
rows, reports, ok = m.run("ko-KR", plan, CENSUS, LABELS, "bin", "scratch", out=lambda _l: None)
case("MUTANT: without the stop a run goes on past a window it could not close", ok is True and calls == ["A", "B"])

# ---- filing ------------------------------------------------------------------------------------------
nav_row = {"surface": "project.lifecycle", "path": "AXWindow[저장]/AXButton", "role": "AXButton", "title": "취소",
           "description": None, "help": None, "value": None, "identifier": "CancelButton"}
window_row = dict(nav_row, surface="arrange.window")
case("a navigated row names its own surface", records.classify(nav_row, "ko-KR") == "project.lifecycle")
case("a main-window row is still placed by area", records.classify(window_row, "ko-KR") is None
     or records.classify(window_row, "ko-KR") != "project.lifecycle")
plan_json = json.loads((OBS / "nav-plan.json").read_text(encoding="utf-8"))
case("every step names a surface the taxonomy knows",
     all(f"`{s['surface']}`" in (HERE.parent / "docs/observations/SURFACES.md").read_text(encoding="utf-8") for s in plan_json["steps"]),
     [s["surface"] for s in plan_json["steps"]])
case("no step carries a localised string", all(not any(ord(c) > 0x2FF for c in json.dumps(s)) for s in plan_json["steps"]))

if failures:
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: a step is found by the locale's own strings and a step that cannot be undone stops the run")
