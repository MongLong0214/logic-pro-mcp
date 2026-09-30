#!/usr/bin/env python3
"""Every acceptance spec in `docs/acceptance/` is one the verifier admits, offline, and decides.

A spec is the text a live run is judged by (`docs/acceptance/SCHEMA.md`). Three things can be wrong
with one while nothing notices until a live run is attempted on it:

  1. `verify.py check-spec` refuses it -- a quote that is not verbatim in its source, a fixture id
     the registry (`setups.SETUPS`) does not declare, a row the schema does not admit. Or it cannot
     read a source at all (exit 3). Exit 3 is a FAILURE here: an unread quote is an unchecked one.
     The guard runs offline, so issue bodies are read from `<spec dir>/issues/<n>.md` through
     `LPM_VERIFY_ISSUE_BODIES`; it never calls `gh` or the network.
  2. A source no row decides. `sources[i]` quotes an acceptance sentence, and a row's `criterion`
     names the source it judges. A source no row names is a sentence the spec claims and nothing
     checks. Sources undecided when this rule was written are listed in `UNDECIDED`, which may only
     shrink: an entry whose source is decided, or gone, is reported until it is deleted.
  3. A UI label written as a literal where the verifier sends or compares it. A spec runs in every
     locale it names, and a label only one language spells that way passes in that language alone.
     The scope is the string values under `steps[].call.params`, `restore[].call.params`,
     `expect[].value`, `restore_expect[].value` and `wait.until.value`, plus string selector values
     in expectation, observation reference and wait paths -- where a string is sent to the product
     or compared with a reading. Path keys and syntax are not labels. A string elsewhere is not
     checked: a `command` such as `arm`, an `as` binding such as `undo`, a probe argument key such as
     `name`, a source quote and a `matches_canon` ref quote are all words, not labels aimed at Logic's
     UI. A value is compared by `strip().lower()` against `locale_labels.localised_canonicals()`, the
     canonicals the policy already knows another language spells differently.

Only `*.json` directly in the spec directory is a spec; `evidence/` is never scanned.

    python3 Scripts/check-acceptance-specs.py

`LPM_ACCEPTANCE_DIR` points the guard at another spec directory; its tests use it.
"""
import glob
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "Scripts"))

from locale_labels import localised_canonicals  # noqa: E402
from verify.predicates import parse_path  # noqa: E402

VERIFY = os.path.join(REPO, "Scripts", "verify", "verify.py")

#: Sources no row decides, keyed by (spec basename, source index), with the reason. May only shrink.
UNDECIDED = {
    ("1020.json", 2): "the pilot's rows judge the read-first set and the refusal; no row yet "
                      "observes that a toggle is not reported as a set",
}

#: Where a string is sent to the product or compared with a reading. (row key, what to read.)
LABEL_SCOPES = ("steps", "restore")
EXPECT_SCOPES = ("expect", "restore_expect")


def spec_dir() -> str:
    return os.environ.get("LPM_ACCEPTANCE_DIR") or os.path.join(REPO, "docs", "acceptance")


def specs(directory: str) -> list:
    """Top-level `*.json` only. `glob` without `**` does not descend, so `evidence/` is never read."""
    return sorted(p for p in glob.glob(os.path.join(directory, "*.json")) if os.path.isfile(p))


def check_spec(path: str, directory: str):
    """(exit code, output) of `verify.py check-spec`, reading issue bodies from `<dir>/issues`."""
    env = dict(os.environ, LPM_VERIFY_ISSUE_BODIES=os.path.join(directory, "issues"))
    try:
        proc = subprocess.run([sys.executable, VERIFY, "check-spec", path], capture_output=True,
                              text=True, env=env, timeout=300)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"could not run check-spec: {exc}"
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def _string_values(value, at: str):
    """(where, text) for every string value inside `value`. Keys are names, not values."""
    if isinstance(value, str):
        yield at, value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from _string_values(item, f"{at}.{key}")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from _string_values(item, f"{at}[{i}]")


def _path_selector_strings(path: str, at: str):
    """Only string values in selectors; the verifier parses keys and syntax separately."""
    _, segments = parse_path(path)
    for segment in segments:
        if segment[0] == "select":
            yield from _string_values(segment[2], f"{at}.{segment[1]}")


def scoped_strings(spec: dict):
    """(where, text) for the strings a spec sends to the product or compares with a reading."""
    for row in spec["rows"]:
        base = f"rows[{row['id']}]"
        for key in LABEL_SCOPES:
            for i, step in enumerate(row.get(key) or []):
                if "call" in step:
                    yield from _string_values(step["call"].get("params"),
                                              f"{base}.{key}[{i}].call.params")
                if "wait" in step:
                    until = step["wait"].get("until") or {}
                    joiner = "" if until["path"].startswith("[") else "."
                    yield from _path_selector_strings(step["as"] + joiner + until["path"],
                                                      f"{base}.{key}[{i}].wait.until.path")
                    if "value" in until:
                        yield from _string_values(until["value"],
                                                  f"{base}.{key}[{i}].wait.until.value")
        for key in EXPECT_SCOPES:
            for i, expectation in enumerate(row.get(key) or []):
                at = f"{base}.{key}[{i}]"
                yield from _path_selector_strings(expectation["path"], f"{at}.path")
                if "ref" in expectation and "obs" in expectation["ref"]:
                    yield from _path_selector_strings(expectation["ref"]["obs"], f"{at}.ref.obs")
                if "value" in expectation:
                    yield from _string_values(expectation["value"], f"{at}.value")


def label_problems(spec: dict, canonicals: dict) -> list:
    out = []
    for where, text in scoped_strings(spec):
        name = canonicals.get(text.strip().lower())
        if name is not None:
            out.append(f"{where}: {text!r} is the canonical of {name}, which another language "
                       f"spells differently; a spec that runs in every locale cannot carry it "
                       f"as a literal")
    return out


def undecided_sources(spec: dict) -> list:
    decided = {row["criterion"] for row in spec["rows"]}
    return [i for i in range(len(spec["sources"])) if i not in decided]


def main() -> int:
    directory = spec_dir()
    canonicals = localised_canonicals()
    if not canonicals:
        print("docs/locale/ui-labels.json carries no localised label -- refusing to report a pass "
              "from an empty vocabulary; run Scripts/locale_labels.py --write")
        return 1
    paths = specs(directory)
    if not paths:
        print(f"{directory}: no acceptance spec found -- that is not a pass")
        return 1

    problems = []
    undecided_seen = set()
    judged = set()
    for path in paths:
        base = os.path.basename(path)
        code, output = check_spec(path, directory)
        if code != 0:
            what = {2: "refused", 3: "a source could not be read (exit 3), so a quote is unchecked"}
            problems.append(f"{path}: check-spec {what.get(code, f'exit {code}')}")
            problems += [f"    {line}" for line in output.splitlines()[-12:]]
            continue
        with open(path, encoding="utf-8") as handle:
            spec = json.load(handle)
        judged.add(base)
        for index in undecided_sources(spec):
            undecided_seen.add((base, index))
            if (base, index) not in UNDECIDED:
                problems.append(f"{path}: sources[{index}] is decided by no row -- no row names "
                                f"criterion {index}, so the sentence it quotes is claimed and "
                                f"never checked")
        problems += [f"{path}: {p}" for p in label_problems(spec, canonicals)]

    for (base, index), _reason in sorted(UNDECIDED.items()):
        if base in judged and (base, index) not in undecided_seen:
            problems.append(f"UNDECIDED[({base!r}, {index})]: that source is now decided by a row "
                            f"or no longer exists -- delete the entry so the list only shrinks")
        elif base not in judged and not os.path.isfile(os.path.join(directory, base)):
            problems.append(f"UNDECIDED[({base!r}, {index})]: {base} is gone -- delete the entry")

    if problems:
        print(f"{len(paths)} acceptance spec(s) under {directory}; problems:")
        for line in problems:
            print(f"  {line}")
        return 1
    print(f"{len(paths)} acceptance spec(s) admitted offline by check-spec, every source decided "
          f"or listed ({len(UNDECIDED)} listed), no localised label as a literal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
