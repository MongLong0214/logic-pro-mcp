#!/usr/bin/env python3
"""Every row of `topLevelMenuTitlesByLocale` must be what Apple's bytes say, not what somebody typed.

Logic's UI language is recognised by three menu-bar titles. That table was hand-typed and held
three locales, so a Logic running in German, Spanish, French, Italian, Portuguese or either Chinese
reported `unknown` -- indistinguishable from a menu bar that could not be read. #892.

It now holds ten, derived from the rows Apple keys those titles under. Derived once is not the same
as derived: a row can be edited afterwards, and a table nothing checks is a table that drifts. This
refuses any row the corpus does not say, offline, against the digests `logic_canon.py build` pinned
into `docs/canon/index/strings.tsv` -- so it runs in CI, where there is no Logic.

It also refuses a table that cannot do its job: two locales whose title sets are equal, or one
whose set is a subset of another's, cannot be told apart by a set comparison, which is how the
product matches. Measured on Logic 12.3 (6674): all ten are distinct and none contains another.
"""
import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() -- the ENTRY POINT -- at a tree that must
#: fail. Without one every case reaches the helpers only, and a `main()` returning 0
#: unconditionally stays green; Scripts/mutation-sweep-guard-tests.py measured that for
#: this guard on 2026-09-18.
SWIFT = os.environ.get("LPM_POLICY_SWIFT") or os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility",
                     "AXLogicProElements+Menu.swift")

#: The rows the three titles are read from, and the locale each column of the table belongs to.
#: `#mti` is Apple's suffix for a menu title; `File#mti` rather than the other row whose English is
#: also `File`, because only this one says `Ablage` in German, which is what a running Logic says.
UNIT = ("Contents/Frameworks/Logic.framework/Versions/A/Resources/Localizable.strings")
KEYS = ("File#mti", "Edit#mti", "Track#mti")

#: product identifier -> the `.lproj` Logic actually ships. Not a region claim: Logic has `de.lproj`,
#: not `de_DE`. `pt-BR` is the one region the bundle evidences -- `pt.lproj` says `Arquivo`, which is
#: Brazilian, where European Portuguese would say `Ficheiro`.
LOCALE_OF = {
    "en-US": "en", "ko-KR": "ko", "ja-JP": "ja", "de-DE": "de", "es-ES": "es",
    "fr-FR": "fr", "it-IT": "it", "pt-BR": "pt", "zh-CN": "zh_CN", "zh-TW": "zh_TW",
}

_TABLE = re.compile(
    r"topLevelMenuTitlesByLocale:\s*\[\(locale: String, titles: Set<String>\)\]\s*=\s*\[(.*?)\n    \]",
    re.S)
_ROW = re.compile(r'\(\s*"([^"]+)"\s*,\s*\[([^\]]*)\]\s*\)')


def _canon():
    spec = importlib.util.spec_from_file_location(
        "logic_canon_for_locale_detection", os.path.join(REPO, "Scripts", "logic_canon.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_table(source: str):
    match = _TABLE.search(source)
    if match is None:
        return None
    return [(locale, [text.strip().strip('"') for text in titles.split(",") if text.strip()])
            for locale, titles in _ROW.findall(match.group(1))]


def check(source: str, canon) -> list:
    failures = []
    table = parse_table(source)
    if table is None:
        return [f"{os.path.relpath(SWIFT, REPO)}: `topLevelMenuTitlesByLocale` is not in the shape "
                f"this guard reads. It is the only thing that decides Logic's UI language, so a "
                f"shape nothing can check is worse than the three-locale table it replaced."]

    missing = sorted(set(LOCALE_OF) - {locale for locale, _ in table})
    if missing:
        failures.append(
            f"the table has no row for {missing}. Logic ships ten `.lproj` and a language with no "
            f"row here reports `unknown`, which is also what an unreadable menu bar reports.")

    index = canon.load_index("strings")
    for locale, titles in table:
        short = LOCALE_OF.get(locale)
        if short is None:
            failures.append(f"{locale!r} is not a locale Logic ships. {sorted(LOCALE_OF)}")
            continue
        if len(titles) != len(KEYS):
            failures.append(f"{locale}: {len(titles)} titles, expected {len(KEYS)}")
            continue
        for key, title in zip(KEYS, titles):
            pinned = index.get((UNIT, short, key, "value"))
            if pinned is None:
                failures.append(
                    f"{locale}: {key} is not pinned for {short}. Run `Scripts/logic_canon.py build` "
                    f"on a machine with Logic -- a row nobody pinned cannot be checked here.")
                continue
            if canon.short_digest(title) != pinned:
                failures.append(
                    f"{locale}: the table says {title!r} for {key}, and Apple's pinned row does "
                    f"not. A typed title is a guess about Logic; this one is checkable and wrong.")

    sets = {locale: set(titles) for locale, titles in table}
    for left in sorted(sets):
        for right in sorted(sets):
            if left < right and sets[left] == sets[right]:
                failures.append(f"{left} and {right} have the same titles, so no set comparison "
                                f"can tell them apart.")
            elif left != right and sets[left] and sets[left] < sets[right]:
                failures.append(f"{left}'s titles are a subset of {right}'s, so a Logic in {right} "
                                f"matches {left} too and detection is ambiguous.")
    return failures


def main() -> int:
    with open(SWIFT, encoding="utf-8") as handle:
        source = handle.read()
    failures = check(source, _canon())
    if failures:
        print(f"{len(failures)} problem(s) with locale detection:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    table = parse_table(source)
    print(f"locale detection is derived: {len(table)} locales, "
          f"{len(table) * len(KEYS)} titles, every one a digest Apple's corpus pinned")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
