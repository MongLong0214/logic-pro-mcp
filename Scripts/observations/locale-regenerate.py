#!/usr/bin/env python3
"""Feed a locale's census records into the ledger, as a DIFF, and regenerate the projection.

    locale-regenerate.py LOCALE                              show what the census would change
    locale-regenerate.py LOCALE --apply                      write the confirmations and regenerate
    locale-regenerate.py LOCALE --apply --accept-changed L   also take label L's changed reading
    locale-regenerate.py LOCALE --apply --accept-new L       also add the aligned new variant of L to Swift

One command per locale. The inputs are the observation records `label-census.py` filed for LOCALE on
the release `AXLocalePolicy.currentLogicVersion`/`Build` declares; nothing else is read from Logic.

WHAT IT REFUSES, before it reads a single row. A record is refused if its `host` names no Logic
version or no build, if it is an explicit `binding: unknown` host, if it names a release other than the
declared one, if it was taken in another locale, or if it cites no evidence census. A reading of a
different Logic is not evidence for this one, and a reading of an unknown Logic is evidence for nothing.

WHAT IT SHOWS, and why it is a diff. For every label the census touches:

    CONFIRMED   the string a prior reading recorded is still what Logic shows; its provenance moves to
                the new record, which names the new release. Written by `--apply`.
    CHANGED     the same variant is found, but the text Logic carried on that element is not the text
                the prior reading quoted. NOT written until the label is named with `--accept-changed`:
                a label that changed in a Logic update is exactly the one that must be looked at.
    UNCONFIRMED a variant that WAS read in this locale and was not found by the census. Nothing is
                written; its provenance stays on the old release, so it stays counted as not measured
                on the current one, and a person decides whether Logic dropped it.
    NEW         the census read something for this label where the ledger has no reading yet (a variant
                or canonical never sighted in this locale). Written by `--apply`.
    NEW VARIANT the aligned walk of the en-US census and this one puts a string where this label's
                canonical sits, and it is not one of the label's variants. A candidate for Swift, not
                written until the label is named with `--accept-new`.

Swift stays the compiled authority and the JSON a projection: the only edit this makes to Swift is
appending an accepted variant to its LabelSet; everything else lands in the ledger JSON, bound to the
records by `Scripts/locale_labels.py --write --bind-record`.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------------------------------
# THE GATE
# --------------------------------------------------------------------------------------------------
def gate_record(record_id, locale, declared, obs_dir):
    """`(record, refusal)`: the record when it may be fed in, else why it may not.

    The declared release is compared as version AND build; a missing, empty, `?` or `unknown` axis is a
    refusal of its own, distinct from a mismatch, because the remedy differs (re-file the census with a
    probe that can read the Info.plist, versus take a census on the declared Logic).
    """
    path = os.path.join(obs_dir, f"{record_id}.json")
    try:
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return None, f"{record_id}: not a readable record under {obs_dir}"
    host = record.get("host") if isinstance(record.get("host"), dict) else {}
    if host.get("binding") == "unknown":
        return None, f"{record_id}: its host is explicitly `binding: unknown` -- no Logic version or build"
    for axis in ("version", "build"):
        if str(host.get(axis) or "").strip() in ("", "?", "unknown"):
            return None, f"{record_id}: its host carries no Logic {axis}"
    if (host["version"], host["build"]) != (declared["version"], declared["build"]):
        return None, (f"{record_id}: read on Logic {host['version']} ({host['build']}), but the declared "
                      f"current release is {declared['version']} ({declared['build']})")
    if host.get("locale") != locale:
        return None, f"{record_id}: taken in {host.get('locale')!r}, not {locale!r}"
    if not record.get("evidence"):
        return None, f"{record_id}: cites no evidence census, so nothing in it can be re-read"
    return record, None


def discover(locale, declared, obs_dir):
    """Ids of this locale's census records that are on the declared release, newest first."""
    found = []
    for name in sorted(os.listdir(obs_dir), reverse=True):
        if not (name.endswith("-census.json") and f"-{locale}-" in name):
            continue
        record, _ = gate_record(name[:-5], locale, declared, obs_dir)
        if record is not None:
            found.append(name[:-5])
    return found


# --------------------------------------------------------------------------------------------------
# THE DIFF
# --------------------------------------------------------------------------------------------------
def _current(block_or_map_version, block_or_map_build, declared):
    return (block_or_map_version, block_or_map_build) == (declared["version"], declared["build"])


def plan_changes(labels, locale, hits_by_label, declared):
    """Classify what the census says against what the ledger holds. Pure; touches nothing.

    `hits_by_label` is `locale-propose.main`'s proposals: `{label: [{"string", "observed", ...}]}`.
    """
    plan = {"confirmed": [], "changed": [], "new": [], "unconfirmed": [], "already_current": [],
            "template": []}
    for name, hits in sorted(hits_by_label.items()):
        entry = labels.get(name) or {}
        seen, texts = {}, {}
        for hit in hits:
            seen.setdefault(hit["string"], hit)
            texts.setdefault(hit["string"], set()).add(hit["observed"])
        for string, hit in sorted(seen.items()):
            if entry.get("match") == "template" and string != entry.get("canonical"):
                # A TEMPLATE variant (`%@ 실행 취소`) is never a substring of what Logic shows -- the
                # element reads `무제 실행 취소` -- so a reading of it cannot satisfy the guard's rule
                # that `observed` contains the variant, and the proposer would write a block the guard
                # then refuses. Reported, never written.
                plan["template"].append({"label": name, "string": string, "observed": hit["observed"]})
                continue
            if string in (entry.get("variants") or []):
                block = (entry.get("provenance") or {}).get(string)
                if block and block.get("locale") == locale:
                    if _current(block.get("logic_version"), block.get("logic_build"), declared):
                        plan["already_current"].append({"label": name, "string": string})
                    elif block.get("observed") in texts[string]:
                        # Any row that still carries the text the prior reading quoted confirms it. The
                        # proposer lists hits in census order, and under containment several rows can
                        # carry one variant, so comparing against the FIRST would call a stable label
                        # changed because a different element came first.
                        plan["confirmed"].append({"label": name, "string": string, "kind": "variant",
                                                  "observed": hit["observed"],
                                                  "was": block.get("logic_version")})
                    else:
                        plan["changed"].append({"label": name, "string": string, "kind": "variant",
                                                "was": block.get("observed"), "now": hit["observed"]})
                else:
                    plan["new"].append({"label": name, "string": string, "kind": "variant",
                                        "observed": hit["observed"]})
            elif string == entry.get("canonical"):
                cell = (entry.get("coverage") or {}).get(locale)
                if cell in ("measured", "identifier") and (entry.get("coverage_records") or {}).get(locale):
                    if _current((entry.get("coverage_logic_version") or {}).get(locale),
                                (entry.get("coverage_logic_build") or {}).get(locale), declared):
                        plan["already_current"].append({"label": name, "string": string})
                    else:
                        plan["confirmed"].append({"label": name, "string": string, "kind": "coverage",
                                                  "observed": hit["observed"],
                                                  "was": (entry.get("coverage_logic_version") or {}).get(locale)})
                elif cell in ("derived", "unmeasured"):
                    plan["new"].append({"label": name, "string": string, "kind": "coverage",
                                        "observed": hit["observed"]})
    for name, entry in sorted(labels.items()):
        sighted = {h["string"] for h in hits_by_label.get(name, [])}
        for variant, block in sorted((entry.get("provenance") or {}).items()):
            if (isinstance(block, dict) and block.get("locale") == locale
                    and not _current(block.get("logic_version"), block.get("logic_build"), declared)
                    and variant not in sighted):
                plan["unconfirmed"].append({"label": name, "string": variant,
                                            "record": block.get("record"),
                                            "was": block.get("logic_version")})
        cell = (entry.get("coverage") or {}).get(locale)
        if (cell in ("measured", "identifier") and (entry.get("coverage_records") or {}).get(locale)
                and not _current((entry.get("coverage_logic_version") or {}).get(locale),
                                 (entry.get("coverage_logic_build") or {}).get(locale), declared)
                and entry.get("canonical") not in sighted
                and not any(isinstance(b, dict) and b.get("locale") == locale
                            for b in (entry.get("provenance") or {}).values())):
            plan["unconfirmed"].append({"label": name, "string": entry.get("canonical"),
                                        "record": entry["coverage_records"][locale],
                                        "was": (entry.get("coverage_logic_version") or {}).get(locale)})
    return plan


def writable(hits, plan, accept_changed):
    """`(hits that may be written, changed readings held back)`.

    A changed reading is written only for a label the operator named, and a template reading is never
    written. Everything else the census found is a confirmation or a first reading and goes in.
    """
    held_back = [i for i in plan["changed"] if i["label"] not in set(accept_changed)]
    skip = {(i["label"], i["string"]) for i in held_back}
    skip |= {(i["label"], i["string"]) for i in plan["template"]}
    todo = {}
    for name, label_hits in hits.items():
        kept = [h for h in label_hits if (name, h["string"]) not in skip]
        if kept:
            todo[name] = kept
    return todo, held_back


def render_diff(plan, new_variants, locale, declared):
    """The diff a person reads before `--apply`."""
    lines = [f"{locale} against Logic {declared['version']} ({declared['build']}):"]
    for key, title in (("confirmed", "CONFIRMED"), ("new", "NEW"), ("already_current", "ALREADY CURRENT")):
        lines.append(f"  {title}: {len(plan[key])}")
    if plan["template"]:
        lines.append(f"  TEMPLATE: {len(plan['template'])}  (matched by template, which no reading can "
                     f"quote; read by hand, not written): "
                     + ", ".join(sorted({i['label'] for i in plan['template']})))
    lines.append(f"  CHANGED: {len(plan['changed'])}")
    for item in plan["changed"]:
        lines.append(f"    ~ {item['label']}")
        lines.append(f"        - {item['was']!r}")
        lines.append(f"        + {item['now']!r}")
    lines.append(f"  UNCONFIRMED: {len(plan['unconfirmed'])}  (read before, not found now; nothing written)")
    for item in plan["unconfirmed"]:
        lines.append(f"    ? {item['label']}: {item['string']!r} (last read on {item['was']} in {item['record']})")
    lines.append(f"  NEW VARIANT: {len(new_variants)}  (aligned from en-US; Swift is not touched without --accept-new)")
    for name, cand in sorted(new_variants.items()):
        lines.append(f"    + {name}: {cand['base']!r} -> {cand['target']!r}"
                     + ("" if cand.get("scoped") else "   (rests on role alone)"))
    return "\n".join(lines)


# --------------------------------------------------------------------------------------------------
# SWIFT
# --------------------------------------------------------------------------------------------------
def swift_literal(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def add_variant(swift_text, label, variant):
    """`swift_text` with `variant` appended to the named LabelSet's `variants`, or ValueError.

    Only the named `static let NAME = LabelSet(...)` shape; an inline set has no name to be asked for.
    The edit keeps the file's own layout: one element per line when the array already has one per line.
    """
    match = re.search(r"static let " + re.escape(label) + r" = LabelSet\(\s*canonical:\s*\"(?:[^\"\\]|\\.)*\",\s*"
                      r"variants:\s*\[([^\]]*)\]", swift_text, re.S)
    if not match:
        raise ValueError(f"{label}: no named `static let {label} = LabelSet(...)` in the Swift")
    body = match.group(1)
    literal = swift_literal(variant)
    if literal in body:
        raise ValueError(f"{label}: already lists {variant!r}")
    start = match.start(1)
    if "\n" in body:
        last = [ln for ln in body.split("\n") if ln.strip()]
        indent = re.match(r"\s*", last[-1]).group(0) if last else "            "
        stripped = body.rstrip()
        tail = body[len(stripped):]
        joiner = "" if stripped.endswith(",") else ","
        new_body = f"{stripped}{joiner}\n{indent}{literal},{tail}"
    else:
        stripped = body.rstrip()
        sep = ", " if stripped and not stripped.endswith(",") else (" " if stripped else "")
        new_body = f"{stripped}{sep}{literal}"
    return swift_text[:start] + new_body + swift_text[start + len(body):]


# --------------------------------------------------------------------------------------------------
# DRIVER
# --------------------------------------------------------------------------------------------------
def _evidence_census(record, obs_dir):
    for rel in record.get("evidence") or []:
        path = os.path.join(obs_dir, rel)
        try:
            with open(path, encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict) and "census" in doc and "host" in doc:
            return path, doc
    return None, None


def run(argv=None, repo=REPO):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("locale")
    parser.add_argument("--records", nargs="*", default=None, help="record ids to feed in")
    parser.add_argument("--base-records", nargs="*", default=None,
                        help="en-US census record ids for the alignment (default: discovered)")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--accept-changed", nargs="*", default=[])
    parser.add_argument("--accept-new", nargs="*", default=[])
    args = parser.parse_args(argv)

    labels_mod = _load("locale_labels_for_regenerate", os.path.join(repo, "Scripts", "locale_labels.py"))
    swift = os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
    declared = labels_mod.declared_logic(swift)
    if declared is None:
        print("REFUSED: AXLocalePolicy.swift declares no current Logic.")
        return 2
    obs_dir = labels_mod.OBS_DIR
    locale = args.locale
    if locale not in labels_mod.SUPPORTED_LOCALES:
        print(f"REFUSED: {locale} is not one of {labels_mod.SUPPORTED_LOCALES}")
        return 2

    named = args.records
    ids = named if named else discover(locale, declared, obs_dir)
    if not ids:
        print(f"REFUSED: no census record for {locale} on Logic {declared['version']} "
              f"({declared['build']}). Run `Scripts/observations/label-census.py run {locale} --write` "
              f"on that Logic first.")
        return 2
    records, refusals = {}, []
    for rid in ids:
        record, why = gate_record(rid, locale, declared, obs_dir)
        (records.__setitem__(rid, record) if record else refusals.append(why))
    if refusals:
        for why in refusals:
            print(f"REFUSED {why}")
        print("Nothing was read and nothing was written.")
        return 2

    propose = _load("locale_propose_for_regenerate", os.path.join(HERE, "locale-propose.py"))
    align = _load("locale_align_for_regenerate", os.path.join(HERE, "locale-align.py"))
    labels_path = labels_mod.JSON_PATH
    census_path, census = None, None
    for record in records.values():
        census_path, census = _evidence_census(record, obs_dir)
        if census:
            break
    if not census:
        print("REFUSED: none of the records cites an evidence census this tool can read.")
        return 2
    doc = labels_mod.load_json()
    base_locale, _host, hits, _unmatched = propose.main(census_path, labels_path)
    plan = plan_changes(doc.get("labels") or {}, locale, hits, declared)

    new_variants = {}
    if locale != "en-US":
        base_ids = args.base_records if args.base_records else discover("en-US", declared, obs_dir)
        for rid in base_ids:
            record, _ = gate_record(rid, "en-US", declared, obs_dir)
            _path, base_census = _evidence_census(record, obs_dir) if record else (None, None)
            if base_census:
                found, _ambiguous, _containing, _stats = align.candidates(base_census, census,
                                                                         doc.get("labels") or {})
                new_variants = found
                break

    print(render_diff(plan, new_variants, locale, declared))
    if not args.apply:
        print("\n(dry run: nothing written; pass --apply to write the confirmations)")
        return 0

    # --- apply -------------------------------------------------------------------------------------
    changed_ok = set(args.accept_changed)
    for name in args.accept_new:
        if name not in new_variants:
            print(f"REFUSED: --accept-new {name}: the aligned census proposes no new variant for it.")
            return 2
    if args.accept_new:
        with open(swift, encoding="utf-8") as handle:
            text = handle.read()
        for name in args.accept_new:
            try:
                text = add_variant(text, name, new_variants[name]["target"])
            except ValueError as exc:
                print(f"REFUSED: {exc}")
                return 2
        with open(swift, "w", encoding="utf-8") as handle:
            handle.write(text)
        subprocess.run([sys.executable, os.path.join(repo, "Scripts", "locale_labels.py"), "--write"],
                       check=True)
        doc = labels_mod.load_json()
        _l, _h, hits, _u = propose.main(census_path, labels_path)
        plan = plan_changes(doc.get("labels") or {}, locale, hits, declared)

    todo, held_back = writable(hits, plan, changed_ok)
    # Stale readings of what the census CONFIRMED (or the operator accepted as changed) are cleared so
    # the proposer, which never overwrites an existing block, writes the new one.
    refresh = {(i["label"], i["string"], i["kind"]) for i in plan["confirmed"]}
    refresh |= {(i["label"], i["string"], i["kind"]) for i in plan["changed"] if i["label"] in changed_ok}
    raw = json.load(open(labels_path, encoding="utf-8"))
    for name, string, kind in refresh:
        entry = raw["labels"][name]
        if kind == "variant":
            (entry.get("provenance") or {}).pop(string, None)
        else:
            entry["coverage"][locale] = "unmeasured"
            for key in ("coverage_records", "coverage_roles", "coverage_attributes", "coverage_paths",
                        "coverage_identifiers", "coverage_logic_version", "coverage_logic_build",
                        "coverage_record_sha256", "coverage_currency", "coverage_absent"):
                (entry.get(key) or {}).pop(locale, None)
    with open(labels_path, "w", encoding="utf-8") as handle:
        handle.write(labels_mod.render(raw))
    by_surface = {r["surface"]: rid for rid, r in records.items()}
    n_prov, n_cov = propose.apply(labels_path, census, todo, by_surface)
    print(f"wrote {n_prov} provenance block(s) and {n_cov} coverage citation(s)")
    bind = []
    for rid in records:
        bind += ["--bind-record", rid]
    subprocess.run([sys.executable, os.path.join(repo, "Scripts", "locale_labels.py"), "--write", *bind],
                   check=True)
    if held_back:
        print(f"HELD BACK: {len(held_back)} changed reading(s) were not written; name each label with "
              f"--accept-changed to take it")
    return subprocess.run([sys.executable, os.path.join(repo, "Scripts", "locale_labels.py"), "--check"]).returncode


if __name__ == "__main__":
    sys.exit(run())
