#!/usr/bin/env python3
"""A Python helper the installer SHIPS must not spell Logic's interface itself.

WHY THIS EXISTS
---------------
`Scripts/install.sh` installs five Python helpers into the share directory beside the binary. They
are product, not harness -- and every locale rule in this repository was written as though none of
them existed: `check-policy-literals-against-canon.py` and `check-ax-comparisons-use-labelsets.py`
scan `Sources/` and `Scripts/livekit/`, `check-livekit-ui-literals.py` scans `Scripts/livekit/`,
and `ci-forbid-hardcoded-menu-bar-item.sh` scans `Sources/`.

So `logic_bounce_ui.py` drove Logic's Bounce dialog through six hand-typed English-and-Korean
tables for as long as it has existed, and the bounce flow worked in two of the ten languages Logic
ships. Nothing could see it (#919).

WHAT IT REFUSES
---------------
A string literal containing Hangul, kana or Han in a file `install.sh` installs. The set of files
is DERIVED from the installer rather than listed here, because a list would go stale the first time
somebody ships a sixth helper -- which is the failure this guard is downstream of.

Escapes are resolved first: `"\\u{BBF9}서"` is `믹서`, and a rule that reads raw bytes does not know
that. Python spells them `\\uBBF9`, so both forms are folded.

WHAT IT DOES NOT REFUSE
-----------------------
Latin-script labels. `pcm` and `audio tail` are in a shipped table and are correct there: Apple
does not translate them, so matching them by literal is locale-independent -- the same condition
that exempts `MIDI` from the AX-comparison rule. Catching those needs the corpus, and that guard
already exists for the scopes it covers; widening it is a bigger change than this one.

The vocabulary belongs in `AXLocalePolicy` and reaches these helpers through
`Scripts/logic_ui_labels.py`, which `Scripts/locale_labels.py --write` generates and the installer
ships beside them.

Exit: 0 = no shipped helper spells a label - 1 = one does
"""
import os
import re
import importlib.util
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() at a tree that must fail.
INSTALLER = os.environ.get("LPM_INSTALL_SCRIPT") or os.path.join(REPO, "Scripts", "install.sh")
SCRIPTS = os.environ.get("LPM_SCRIPTS_DIR") or os.path.join(REPO, "Scripts")

_CJK = re.compile(r"[\uac00-\ud7a3\u3040-\u309f\u30a0-\u30ff\u4e00-\u9fff]")
_LITERAL = re.compile(r"""(?<!\\)(['"])((?:(?!\1)[^\\\n]|\\.)*)\1""")
_ESCAPE = re.compile(r"\\u\{?([0-9A-Fa-f]{1,8})\}?")
#: The generated module is the one shipped file that MUST carry them -- it is the vocabulary.
GENERATED = "logic_ui_labels.py"
#: Below this length a literal is more likely a dict key or a format token than a
#: label, and the corpus is large enough that short strings collide. Four is where
#: `OK` and `Off` fall out and `Save` stays in.
MINIMUM_LITERAL = 4


def shipped_helpers() -> list:
    """The `logic_*.py` files `install.sh` installs, read from the installer itself."""
    try:
        with open(INSTALLER, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        print(f"cannot read {INSTALLER}: {exc}", file=sys.stderr)
        return []
    return sorted(set(re.findall(r"logic_[a-z0-9_]+\.py", text)))


def _resolved(raw: str) -> str:
    def one(match):
        try:
            return chr(int(match.group(1), 16))
        except (ValueError, OverflowError):
            return match.group(0)
    return _ESCAPE.sub(one, raw)


#: The canon module, loaded once. `None` on a tree without the canon axis, which makes the
#: corpus rule ABSTAIN rather than refuse -- and the abstention is reported, because a rule that
#: goes quiet is how a guard stops guarding without anybody noticing.
_CANON = {}


def _canon():
    if "module" not in _CANON:
        try:
            spec = importlib.util.spec_from_file_location(
                "logic_canon_for_shipped_literals", os.path.join(REPO, "Scripts", "logic_canon.py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            _CANON["module"] = module
        except Exception as exc:  # noqa: BLE001 -- any failure here means "cannot ask"
            _CANON["module"] = None
            _CANON["why"] = str(exc)
    return _CANON["module"]


#: A literal in KEY POSITION is a protocol key, not a label: `{"name": x}` and `v["name"]`.
#: Measured on the real tree the moment the corpus rule was aimed at it -- all five findings were
#: `'name'`, every one of them a dict key, because Apple does translate a string spelled `name`
#: somewhere in 605,190 entries. Length alone cannot separate those: `Save` is four characters and
#: so is `name`. POSITION can, and it is a property of the code rather than of the string.
_KEY_POSITION = re.compile(r"""\s*:""")
_SUBSCRIPT = re.compile(r"""\[\s*$""")


def _is_key_position(line: str, match) -> bool:
    """Whether this literal is a dict key or a subscript rather than a value."""
    after = line[match.end():]
    before = line[:match.start()]
    return bool(_KEY_POSITION.match(after)) or bool(_SUBSCRIPT.search(before))


#: Literals that collide with an Apple value while being something else entirely, keyed by the
#: literal AND the expression it sits in -- never by the literal alone, and never line-wide.
#: That shape is #891's finding: a marker that exempted a whole LINE made three real `'Save'`
#: findings disappear because they shared it with an exempt word.
#:
#: Each entry is a MEASURED collision, not a convenience:
#:   `"status": "error"` -- this product's own envelope vocabulary. Spanish happens to ship
#:       `error` as a value, which says nothing about the JSON key we emit beside it.
#:   `"Logic Pro"` as a PROCESS name -- System Events matches the process by U+0020 while the
#:       AXMenuBarItem title is `Logic\u{00A0}Pro`. Two different strings that read alike,
#:       measured 2026-09-15; `applicationMenuBarItem` is about the second one and this is not it.
PROTOCOL_LITERALS = (
    ('"status": "error"', "error"),
    # The READING side of the same envelope. Exempting only the writer left two comparisons that
    # test the value this product itself emitted two functions earlier.
    ('status == "error"', "error"),
    ("LOGIC_APP_NAME =", "logic pro"),
    ('"process_name":', "logic pro"),
)


def _is_protocol_literal(line: str, text: str) -> bool:
    """Whether this literal is exempt HERE -- its own spelling, in an expression that names it."""
    folded = text.strip().lower()
    return any(marker in line and folded == literal for marker, literal in PROTOCOL_LITERALS)


def _apple_ships(canon, text: str):
    """The first `source/locale` whose corpus holds this exact value, or None.

    The same walk `locale_labels._apple_ships` does, and for the same reason: a string present in
    ANY locale's corpus is Apple's, whatever script it is written in.
    """
    manifest = canon.load_manifest()
    for source, block in (manifest.get("sources") or {}).items():
        for locale in (block.get("locales") or []):
            if locale == "-":
                continue
            try:
                if not canon.is_absent(source, locale, text):
                    return f"{source}/{locale}"
            except canon.CanonError:
                continue
    return None


def translated_offenders() -> tuple:
    """Literals a shipped helper spells that Apple TRANSLATES. Returns (problems, abstained).

    The CJK rule catches a Korean, Japanese or Chinese label by its characters. It cannot see
    `Bouncen`, `Annuler`, `Abbrechen` or `Renderizar` -- five of the ten languages Logic ships
    write their interface in Latin script, and a helper carrying one of those works in exactly
    that language and no other. #919 was the Korean-and-English half of this defect; this is the
    other half, and the limit recorded on that commit said the corpus was what it would take.

    The question is "IS THIS A VALUE APPLE SHIPS", asked against the committed absence sets --
    not "does Apple translate this English string". That distinction is the whole rule and I got
    it backwards first: `is_translated` is keyed by the ENGLISH value, so it answers False for
    `Bouncen`, which is the translation rather than the thing translated. A German label is
    exactly what this rule exists to catch, so a predicate that cannot see one is no predicate.

    Absence is proved offline from `docs/canon/absence/`, so this runs on a machine that has
    never had Logic. `pcm` and `audio tail` stay exempt by DERIVATION -- they are absent from
    every corpus -- rather than by a list somebody maintains.

    Short literals are skipped. A three-character string is far more likely to be a dict key or a
    format token than a label, and the corpus is large enough that short strings collide. That is
    a deliberate blind spot in the direction that asks for work rather than hiding a finding --
    the same trade `is_translated`'s own docstring describes.
    """
    canon = _canon()
    if canon is None:
        return [], f"the canon axis could not be loaded ({_CANON.get('why', 'unknown')})"
    problems = []
    for name in shipped_helpers():
        if name == GENERATED:
            continue
        path = os.path.join(SCRIPTS, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for number, line in enumerate(source.split("\n"), 1):
            if line.lstrip().startswith("#"):
                continue
            for match in _LITERAL.finditer(line):
                text = _resolved(match.group(2)).strip()
                if len(text) < MINIMUM_LITERAL or _CJK.search(text):
                    continue
                if _is_key_position(line, match) or _is_protocol_literal(line, text):
                    continue
                locale = _apple_ships(canon, text)
                if locale:
                    problems.append(
                        f"{name}:{number}: {text!r} is a value Apple ships ({locale})")
    return problems, None


def offenders() -> list:
    problems = []
    for name in shipped_helpers():
        if name == GENERATED:
            continue
        path = os.path.join(SCRIPTS, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for number, line in enumerate(source.split("\n"), 1):
            if line.lstrip().startswith("#"):
                continue
            for match in _LITERAL.finditer(line):
                text = _resolved(match.group(2))
                if text.strip() and _CJK.search(text):
                    problems.append(f"{name}:{number}: {text!r}")
    return problems


def main() -> int:
    helpers = shipped_helpers()
    if not helpers:
        print("install.sh names no logic_*.py helper, so this guard has nothing to check and an "
              "empty expectation would pass against anything.", file=sys.stderr)
        return 1
    problems = offenders()
    translated, abstained = translated_offenders()
    if abstained:
        # REPORTED, not swallowed. This half of the rule is the one that sees Latin-script labels,
        # and a tree where it silently stops asking is a tree where five of Logic's ten languages
        # go back to being invisible.
        print(f"the corpus rule did not run: {abstained}", file=sys.stderr)
        return 1
    problems = problems + translated
    if problems:
        print(f"{len(problems)} interface literal(s) in a helper the installer SHIPS:",
              file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"\nThese files are installed beside the binary, so a label spelled here works in "
              f"whatever language it is written in. Add it to AXLocalePolicy, export it through "
              f"Scripts/locale_labels.py's SHIPPED_LABELS, and import {GENERATED}.",
              file=sys.stderr)
        return 1
    print(f"none of the {len(helpers)} shipped Python helper(s) spells a Logic label; the "
          f"vocabulary reaches them through {GENERATED}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
