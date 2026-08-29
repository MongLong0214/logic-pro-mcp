#!/usr/bin/env python3
"""The live kit's locale aliases must not drift from `AXLocalePolicy`.

`evidence.py` carries `CONTROL_BAR_NAMES` and `TRACK_HEADER_NAMES` because the harnesses cannot
import Swift. That makes them a SECOND COPY of a label list, and a second copy goes stale the day
someone adds a locale to the first — silently, because a missing alias does not look like a bug: the
band lookup answers "no element with that exact AXDescription", the harness fails a precondition
about a window frame, and nothing in that message says the word it wanted was spelled for another
language.

Measured 2026-08-29, which is why this exists: three harnesses passed `"Control Bar"` to the band
tool on a Logic running in Korean. Each failed at a precondition unrelated to its own subject, so
none of them could produce evidence at all on this machine — and under the source-coverage rule a
harness that cannot run leaves its subject unproven however good its checks are.

A copy with a check is a copy that cannot go stale. This is that check.

WHAT IT DOES NOT DO: it does not require the two lists to be EQUAL. The policy is normalised and
matched leniently by the product; the live kit compares exactly, so it legitimately carries the
cased spellings Logic actually emits (`Tracks header`) beside the lower-cased policy variants. The
rule is one-directional and that is the direction that matters — every policy variant must be
reachable from the live kit, so a locale the product learned is a locale a harness can find.
"""
import ast
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICY = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
KIT = os.path.join(REPO, "Scripts", "livekit", "evidence.py")

# `(python name, swift LabelSet name)`
PAIRS = [
    ("CONTROL_BAR_NAMES", "controlBarGroupLabel"),
    ("TRACK_HEADER_NAMES", "trackHeadersDescription"),
]


def swift_label_set(text, name):
    """`[canonical] + variants` for one `static let <name> = LabelSet(...)`, or None."""
    match = re.search(
        r"static let " + re.escape(name) + r"\s*=\s*LabelSet\((.*?)\)\s*\n",
        text, re.S)
    if not match:
        return None
    body = match.group(1)
    canonical = re.search(r'canonical:\s*"((?:[^"\\]|\\.)*)"', body)
    variants = re.search(r"variants:\s*\[(.*?)\]", body, re.S)
    if not canonical:
        return None
    out = [canonical.group(1)]
    if variants:
        out += re.findall(r'"((?:[^"\\]|\\.)*)"', variants.group(1))
    return out


def python_list(text, name):
    """The literal list assigned to `name` in `evidence.py`, or None."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if name not in [t.id for t in node.targets if isinstance(t, ast.Name)]:
            continue
        try:
            value = ast.literal_eval(node.value)
        except (ValueError, SyntaxError):
            return None
        return list(value) if isinstance(value, (list, tuple)) else None
    return None


def missing(policy_labels, kit_labels):
    """Policy spellings no live-kit alias would match, compared case-insensitively.

    Case is folded because the live kit legitimately carries what Logic EMITS (`Tracks header`)
    while the policy stores normalised variants (`tracks header`); requiring both spellings in both
    places would make the check fail on a difference that changes nothing.
    """
    have = {label.lower() for label in kit_labels}
    return [label for label in policy_labels if label.lower() not in have]


def main():
    try:
        policy_text = open(POLICY, encoding="utf-8").read()
        kit_text = open(KIT, encoding="utf-8").read()
    except OSError as exc:
        print(f"-> FAIL: cannot read a source ({exc})")
        return 1

    failed = 0
    for py_name, swift_name in PAIRS:
        policy_labels = swift_label_set(policy_text, swift_name)
        kit_labels = python_list(kit_text, py_name)
        if policy_labels is None:
            print(f"-> FAIL: AXLocalePolicy.{swift_name} not found — renamed?")
            failed = 1
            continue
        if kit_labels is None:
            print(f"-> FAIL: evidence.{py_name} not found or not a literal list")
            failed = 1
            continue
        gap = missing(policy_labels, kit_labels)
        state = "ok" if not gap else "FAIL"
        print(f"   {state:>4}  {py_name}: {len(kit_labels)} alias(es) cover "
              f"{len(policy_labels) - len(gap)} of {len(policy_labels)} policy spelling(s)")
        if gap:
            print(f"-> FAIL: {swift_name} declares {gap} which no live-kit alias matches")
            print(f"   Add them to evidence.{py_name}, or a harness cannot find that element on a")
            print("   Logic running in that language and will fail a precondition instead.")
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
