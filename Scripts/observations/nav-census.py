#!/usr/bin/env python3
"""The navigation half of a locale census: open each surface the plan names, read it, put it back.

    nav-census.py LOCALE [--write] [--confirm] [--steps a,b] [--list] [--compare]

`label-census.py` reads what is on screen without pressing anything, and that cannot reach a sheet, a dialog,
a window or a popup that only an action opens. This does, one step at a time, through the product's own
operations -- a menu item pressed -- and never by a coordinate, a typed character or an OK button:

    resolve   the menu item for a step is found by what the LOCALE's own census calls it: a label set's strings
              (`nav-plan.json` names the label, never a string), a menu identifier, or a key equivalent
    before    the window set (`locale-nav --windows`) and the project's newest modification time
    open      `locale-nav.swift` presses the one item, waits, reads every window, sheet and menu that appeared
    close     ... and closes what it opened through the surface's own AXCancelButton or AXCloseButton
    after     the window set and the modification time again. They must EQUAL `before`. If they do not, this
              stops at once, files nothing, and exits 3 -- a navigation that cannot be undone is not a census.

A step whose menu item the locale's census cannot resolve (or resolves twice) is reported as UNRESOLVED and
skipped; the label it would have measured stays unmeasured, and that is the honest answer. With `--write` the
rows are filed as a `navigation` census through `label-census.py ingest` (records, evidence, canon citations).

Exit: 0 every step ran and restored; 2 a precondition failed; 3 a step could not be undone.
"""
import argparse
import datetime
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
REPO = os.path.dirname(SCRIPTS)
PLAN = os.path.join(HERE, "nav-plan.json")
PROBE = os.path.join(HERE, "locale-nav.swift")
FIXTURE = os.environ.get("LPM_LOCALE_FIXTURE") or os.path.expanduser(
    "~/.hermes/cache/logic-cto/impl-logic13/R11/fixture/QualFixtureR11.logicx")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def fold(text):
    """Compare menu titles the way the policy does: case, no-break spaces and the three-dot ellipsis."""
    return (text or "").replace(" ", " ").replace("...", "…").replace(" …", "…").strip().casefold()


# --------------------------------------------------------------------------------------------------
# RESOLVING a step's menu item from the locale's own census
# --------------------------------------------------------------------------------------------------
def label_strings(labels, name):
    entry = (labels.get("labels") or {}).get(name)
    if not entry:
        return set()
    return {fold(s) for s in [entry["canonical"]] + list(entry.get("variants") or []) if s}


def _titles(path):
    """The bracketed titles of a menu path, outermost first (names may contain `/`)."""
    return [m.group(2) for m in re.finditer(r"(AX[A-Za-z]+)\[(.*?)\](?=/AX|$)", path)]


def menu_rows(census):
    return [r for r in census["census"] if r.get("surface") == "arrange.menus" and r.get("role") == "AXMenuItem"]


def resolve(strategy, census, labels):
    """`(path, why)`: the unique menu path a strategy names in this census, else None and the reason."""
    rows = menu_rows(census)
    if "identifier" in strategy:
        hits = [r["path"] for r in rows if r.get("identifier") == strategy["identifier"]]
    elif "label" in strategy:
        wanted = label_strings(labels, strategy["label"])
        if not wanted:
            return None, f"no label set named {strategy['label']}"
        parents = label_strings(labels, strategy["under"]) if strategy.get("under") else None
        hits = []
        for r in rows:
            titles = _titles(r["path"])
            if fold(titles[-1]) not in wanted:
                continue
            if parents is not None and not any(fold(t) in parents for t in titles[:-1]):
                continue
            hits.append(r["path"])
    else:
        return None, "a strategy names a label, an identifier or a shortcut"
    hits = sorted(set(hits))
    if len(hits) == 1:
        return hits[0], ""
    return None, f"{len(hits)} menu items match {json.dumps(strategy, ensure_ascii=False)}"


def open_spec(step, census, labels):
    """`(spec, why)` for the first strategy that resolves; a shortcut needs no census."""
    reasons = []
    for strategy in step["open"]:
        if "shortcut" in strategy:
            return {"surface": step["surface"], "settle": step.get("settle", 1.5), "depth": step.get("depth", 10),
                    "open": {"kind": "menu-shortcut", "char": strategy["shortcut"]["char"],
                             "mods": strategy["shortcut"]["mods"]}}, ""
        path, why = resolve(strategy, census, labels)
        if path:
            return {"surface": step["surface"], "settle": step.get("settle", 1.5), "depth": step.get("depth", 10),
                    "open": {"kind": "menu-path", "path": path}}, ""
        reasons.append(why)
    return None, "; ".join(reasons)


# --------------------------------------------------------------------------------------------------
# THE WAY BACK
# --------------------------------------------------------------------------------------------------
def project_mtime(fixture=FIXTURE):
    """The newest modification time (ns) of anything in the project package: a navigation must not move it."""
    newest = 0
    for root, _dirs, files in os.walk(fixture):
        for name in files + [""]:
            try:
                newest = max(newest, os.stat(os.path.join(root, name) if name else root).st_mtime_ns)
            except OSError:
                continue
    return newest


def compile_probe(out_dir):
    binary = os.path.join(out_dir, "locale-nav")
    built = subprocess.run(["swiftc", "-O", PROBE, "-o", binary], capture_output=True, text=True)
    if built.returncode != 0:
        raise RuntimeError(f"cannot compile the navigation probe: {built.stderr.strip()[:300]}")
    return binary


def windows(binary):
    done = subprocess.run([binary, "--windows"], capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"cannot read the window set: {done.stderr.strip()[:200]}")
    return json.loads(done.stdout)


def run_step(binary, spec, scratch, fixture=FIXTURE, runner=subprocess.run):
    """One step. Returns the step's result dict; `restored` is only true if windows AND mtime are equal."""
    before_windows, before_mtime = windows(binary), project_mtime(fixture)
    path = os.path.join(scratch, "spec.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(spec, handle, ensure_ascii=False)
    done = runner([binary, path], capture_output=True, text=True)
    try:
        result = json.loads(done.stdout)
    except ValueError:
        result = {"opened": False, "restored": False, "error": f"the probe printed no result ({done.returncode}): "
                  f"{done.stderr.strip()[:200]}", "census": [], "appeared": [], "closed_by": []}
    after_windows, after_mtime = windows(binary), project_mtime(fixture)
    result["restored"] = bool(result.get("restored")) and after_windows == before_windows
    result["project_untouched"] = after_mtime == before_mtime
    result["windows_before"], result["windows_after"] = before_windows, after_windows
    return result


# --------------------------------------------------------------------------------------------------
# THE CENSUS
# --------------------------------------------------------------------------------------------------
def newest_census(repo, locale, declared, census_evidence):
    """The newest navigation-free census of `locale` on the declared release."""
    best = None
    for path in sorted(glob.glob(os.path.join(repo, "docs", "observations", "evidence",
                                              f"*-{locale}-navigation-free.census.json*"))):
        doc = census_evidence.load(path)
        host = doc.get("host") or {}
        if (host.get("version"), host.get("build")) == (declared["version"], declared["build"]):
            best = doc
    return best


def run(locale, plan, census, labels, binary, scratch, only=None, fixture=FIXTURE, out=print, runner=subprocess.run):
    """Run every step; return `(rows, reports, ok)`. Stops at the first step that was not undone."""
    rows, reports = [], []
    for step in plan["steps"]:
        if only and step["id"] not in only:
            continue
        spec, why = open_spec(step, census, labels)
        if spec is None:
            reports.append({"id": step["id"], "status": "UNRESOLVED", "why": why})
            out(f"  UNRESOLVED {step['id']}: {why}")
            continue
        result = run_step(binary, spec, scratch, fixture, runner)
        status = ("OPENED" if result.get("opened") else "NOT OPENED")
        report = {"id": step["id"], "surface": step["surface"], "status": status, "rows": len(result["census"]),
                  "restored": result["restored"], "project_untouched": result["project_untouched"],
                  "closed_by": result.get("closed_by"), "error": result.get("error")}
        reports.append(report)
        out(f"  {status:10s} {step['id']}: {len(result['census'])} rows, restored={result['restored']}, "
            f"project untouched={result['project_untouched']}" + (f", {result['error']}" if result.get("error") else ""))
        if not (result["restored"] and result["project_untouched"]):
            report["status"] = "NOT RESTORED"
            return rows, reports, False
        rows += result["census"]
    return rows, reports, True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("locale")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--steps", default="")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--compare", action="store_true")
    args = parser.parse_args(argv)
    with open(PLAN, encoding="utf-8") as handle:
        plan = json.load(handle)
    if args.list:
        for step in plan["steps"]:
            print(f"{step['id']:24s} {step['surface']:26s} {json.dumps(step['open'], ensure_ascii=False)}")
        return 0
    labels_mod = _load("nav_labels", os.path.join(SCRIPTS, "locale_labels.py"))
    evidence = _load("nav_evidence", os.path.join(SCRIPTS, "census_evidence.py"))
    declared = labels_mod.declared_logic(os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift"))
    census = newest_census(REPO, args.locale, declared, evidence)
    if census is None:
        print(f"PRECONDITION: no navigation-free census of {args.locale} on Logic {declared['version']} "
              f"({declared['build']}); `label-census.py run {args.locale} --write` first -- the menu paths come from it")
        return 2
    if not os.path.isdir(FIXTURE):
        print(f"PRECONDITION: fixture {FIXTURE} does not exist")
        return 2
    labels = labels_mod.load_json()
    only = {s for s in args.steps.split(",") if s}
    with tempfile.TemporaryDirectory() as scratch:
        try:
            binary = compile_probe(scratch)
            print(f"navigation census, {args.locale}, {len(plan['steps'])} step(s) planned")
            rows, reports, ok = run(args.locale, plan, census, labels, binary, scratch, only)
        except RuntimeError as exc:
            print(f"PRECONDITION: {exc}")
            return 2
    if not ok:
        print("A STEP WAS NOT UNDONE: nothing is filed. Restore Logic by hand before anything else runs.")
        return 3
    doc = {"kind": "navigation", "host": dict(census["host"]), "menu_bar": [], "census": rows}
    if args.compare or not args.write:
        print(f"{len(rows)} rows from {sum(1 for r in reports if r['status'] == 'OPENED')} surface(s); "
              f"{'compared' if args.compare else 'not filed (no --write)'}")
        return 0
    path = os.path.join(tempfile.mkdtemp(), "navigation.census.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, ensure_ascii=False)
    done = subprocess.run([sys.executable, os.path.join(HERE, "label-census.py"), "ingest", args.locale, path,
                           "--write"] + (["--confirm"] if args.confirm else []))
    return done.returncode


if __name__ == "__main__":
    sys.exit(main())
