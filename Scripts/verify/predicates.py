"""The predicate library of the fixed verifier (ADR-027): a closed set of operators over JSON values.

Pure functions. Nothing here reads a file, a clock, the environment or the network, so a verdict
computed from stored observations today is the verdict computed from them tomorrow.

THREE OUTCOMES, NOT TWO
-----------------------
    PASS        the reading exists and satisfies the operator
    FAIL        the reading exists and does not
    UNREADABLE  the reading does not exist: a missing key, an index past the end, a selector that
                matches nothing or more than one element, an observation the runner could not take

A missing path is never FAIL and never PASS. Audit A found "unreadable recorded as absent" re-fixed
five times in the live harnesses: `x.get("isArmed")` folds "the track list did not list the track"
into `None`, and `None` then reads as "not armed". Here it cannot: the path resolver returns an
`Unreadable` and `check` returns UNREADABLE before any operator sees it.

PATHS
-----
A tiny JSONPath subset. The first segment is a bound observation name; the rest walk into it:

    reply.state                  key `state` of the observation bound as `reply`
    post.data[0]                 element 0 of the list under `data`
    post.data[id=15].isArmed     the ONE element of `data` whose `id` equals 15, then `isArmed`
    census.rows[name="Audio 1"]  a selector value is a JSON scalar (15, true, null, "text") or a
                                 bare word, which is read as a string

Keys are `[A-Za-z0-9_$-]+`. A key containing `.`, `[`, `]` or `=` cannot be addressed; that is a
limit, and a path that needs one is refused by the parser rather than guessed at. A selector that
matches two elements is UNREADABLE: "the element" is an identity claim, and two candidates is the
failure `feedback_identity_by_name_is_not_identity` names.

OPERATORS
---------
    eq, ne              strict JSON equality: true is not 1, 1 is 1.0, lists compare in order
    in, not_in          the reading is / is not an element of the operand list
    subset, superset    lists as sets of JSON values
    count_eq, count_ge  length of a list reading against an integer operand
    changed, unchanged  equality against ANOTHER observation (the schema requires an `obs` ref)
    is_null, not_null   the path exists and holds / does not hold null (no operand)
    matches_canon       the reading's canon digest equals the pinned digest the engine resolved

`changed`/`unchanged` compute what `ne`/`eq` compute. They exist as separate names because the
schema binds them to an observation operand, so a row that means "this moved relative to the
pre-state" cannot be written against a typed constant by mistake.

A reading of the wrong type for its operator (count_eq on a string) is FAIL, not UNREADABLE: the
value was read, and it is not what the row says it should be.

NULL AND ABSENCE
----------------
`changed`, `ne` and `not_in` PASS when two values differ, and null differs from every reading, so
a null would satisfy them by absence, whatever the element was: absence counted as success. Under
these three a null anywhere in either value, at any depth (`[null]`, `{"armed": null}`), is
UNREADABLE instead, never PASS. So is a key that one value has and the other lacks at the same
place (for `not_in`, the reading against each element of the list): a missing key is absence too.
Objects are compared key by key and lists index by index; a list element on one side only
is a difference, since a list's length is part of what was read.

`unchanged` PASSES when two values are equal, and two nulls are equal. When the values are equal
and hold a null, at any depth, it is UNREADABLE: two absences agree without showing that nothing
changed. With a null on one side only it FAILS. The other positive operators are as they
were: a null fails them except against a null operand (`eq` with a null on the other side, `in` a
list that holds null) and under `is_null`.
"""
from __future__ import annotations

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from logic_canon import short_digest  # noqa: E402  -- pure: sha256 of the normalized text

PASS = "PASS"
FAIL = "FAIL"
UNREADABLE = "UNREADABLE"
OUTCOMES = (PASS, FAIL, UNREADABLE)


class Found:
    """A value that exists. `None` inside means JSON null, which is a reading, not an absence."""

    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class Unreadable:
    """No value, and why. Never compared, never coerced."""

    __slots__ = ("reason",)

    def __init__(self, reason: str):
        self.reason = reason


# ---------------------------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------------------------

_KEY = r"[A-Za-z0-9_$-]+"
_SEGMENT = re.compile(
    r"\.(?P<key>" + _KEY + r")"
    r"|\[(?P<index>\d+)\]"
    r"|\[(?P<skey>" + _KEY + r")=(?P<sval>\"(?:[^\"\\]|\\.)*\"|[^\]]+)\]"
)
_ROOT = re.compile(_KEY)


def parse_path(path: str):
    """(root name, [segments]) or raise ValueError. A segment is ("key", k), ("index", n) or
    ("select", k, value)."""
    if not isinstance(path, str):
        raise ValueError(f"a path is a string, not {type(path).__name__}")
    root = _ROOT.match(path)
    if not root:
        raise ValueError(f"{path!r} does not start with an observation name")
    at, segments = root.end(), []
    while at < len(path):
        m = _SEGMENT.match(path, at)
        if not m:
            raise ValueError(f"{path!r}: cannot parse from {path[at:]!r}")
        if m.group("key") is not None:
            segments.append(("key", m.group("key")))
        elif m.group("index") is not None:
            segments.append(("index", int(m.group("index"))))
        else:
            segments.append(("select", m.group("skey"), _selector_value(m.group("sval"))))
        at = m.end()
    return root.group(0), segments


def _selector_value(text: str):
    try:
        return json.loads(text)
    except ValueError:
        return text


def walk(value, segments, shown: str = "") -> "Found | Unreadable":
    """Follow segments into a JSON value. Every way of not arriving is Unreadable, with the step."""
    here = shown
    for seg in segments:
        if seg[0] == "key":
            here = f"{here}.{seg[1]}"
            if not isinstance(value, dict):
                return Unreadable(f"{here}: the parent is {kind_of(value)}, not an object")
            if seg[1] not in value:
                return Unreadable(f"{here}: no such key")
            value = value[seg[1]]
        elif seg[0] == "index":
            here = f"{here}[{seg[1]}]"
            if not isinstance(value, list):
                return Unreadable(f"{here}: the parent is {kind_of(value)}, not a list")
            if seg[1] >= len(value):
                return Unreadable(f"{here}: the list has {len(value)} element(s)")
            value = value[seg[1]]
        else:
            _, key, wanted = seg
            here = f"{here}[{key}={json.dumps(wanted, ensure_ascii=False)}]"
            if not isinstance(value, list):
                return Unreadable(f"{here}: the parent is {kind_of(value)}, not a list")
            hits = [e for e in value if isinstance(e, dict) and key in e and same(e[key], wanted)]
            if len(hits) != 1:
                return Unreadable(f"{here}: {len(hits)} elements match; a selector names exactly one")
            value = hits[0]
    return Found(value)


def kind_of(value) -> str:
    return "null" if value is None else type(value).__name__


# ---------------------------------------------------------------------------------------------
# operators
# ---------------------------------------------------------------------------------------------

def same(a, b) -> bool:
    """JSON equality that Python's `==` is not: `True == 1` in Python, and not here."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def _member(x, items) -> bool:
    return any(same(x, y) for y in items)


def _lists(a, b) -> bool:
    return isinstance(a, list) and isinstance(b, list)


def is_int(value) -> bool:
    """A JSON integer. Python counts `True` as an int; JSON does not."""
    return isinstance(value, int) and not isinstance(value, bool)


def _count(a, b) -> bool:
    return isinstance(a, list) and is_int(b)


#: op -> (needs an operand, the test). Closed: the schema enumerates exactly these names.
OPS = {
    "eq": (True, lambda a, b: same(a, b)),
    "ne": (True, lambda a, b: not same(a, b)),
    "in": (True, lambda a, b: isinstance(b, list) and _member(a, b)),
    "not_in": (True, lambda a, b: isinstance(b, list) and not _member(a, b)),
    "subset": (True, lambda a, b: _lists(a, b) and all(_member(x, b) for x in a)),
    "superset": (True, lambda a, b: _lists(a, b) and all(_member(x, a) for x in b)),
    "count_eq": (True, lambda a, b: _count(a, b) and len(a) == b),
    "count_ge": (True, lambda a, b: _count(a, b) and len(a) >= b),
    "changed": (True, lambda a, b: not same(a, b)),
    "unchanged": (True, lambda a, b: same(a, b)),
    "is_null": (False, lambda a, b: a is None),
    "not_null": (False, lambda a, b: a is not None),
    "matches_canon": (True, lambda a, b: isinstance(a, str) and isinstance(b, str)
                      and short_digest(a) == b),
}


#: Operators that PASS on a difference. Under them a null anywhere in either value, or a key only
#: one side has, is UNREADABLE (above).
NULL_IS_UNREADABLE = ("changed", "ne", "not_in")


def nulls(value, here: str = ""):
    """Each place a null sits in `value`, at any depth, as a path suffix ("" is the value itself)."""
    if value is None:
        yield here
    elif isinstance(value, dict):
        for key in sorted(value):
            yield from nulls(value[key], f"{here}.{key}")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from nulls(item, f"{here}[{i}]")


def one_sided_keys(a, b, here: str = ""):
    """Each key that one of two values has and the other lacks at the same place, walking objects
    by key and lists by index."""
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) ^ set(b)):
            yield f"{here}.{key}"
        for key in sorted(set(a) & set(b)):
            yield from one_sided_keys(a[key], b[key], f"{here}.{key}")
    elif isinstance(a, list) and isinstance(b, list):
        for i, (x, y) in enumerate(zip(a, b)):
            yield from one_sided_keys(x, y, f"{here}[{i}]")


def _at(where: str) -> str:
    return f" at {where}" if where else ""


def absence(op: str, a, b):
    """Why `op` over the reading `a` and the operand `b` would be decided by what is not there, or
    None (above). Under changed, ne and not_in: a null anywhere in either value, or a key only one
    side has. Under unchanged: the values are equal and hold a null."""
    if op in NULL_IS_UNREADABLE:
        for side, value in (("reading", a), ("operand", b)):
            where = next(nulls(value), None)
            if where is not None:
                return f"a null in the {side}{_at(where)} cannot show a difference; {op} does not pass on absence"
        for other in (b if op == "not_in" and isinstance(b, list) else [b]):
            where = next(one_sided_keys(a, other), None)
            if where is not None:
                return (f"the key {where} is on one side only, and a missing key cannot show a "
                        f"difference; {op} does not pass on absence")
    elif op == "unchanged" and same(a, b):
        where = next(nulls(a), None)
        if where is not None:
            return (f"both sides hold null{_at(where)}, and two absences agree without showing that "
                    f"nothing changed; unchanged does not pass on absence")
    return None


def check(op: str, actual, operand=None):
    """(outcome, detail) for one operator over an already-resolved reading and operand.

    `actual` and `operand` are Found or Unreadable. An unreadable operand is as unreadable as an
    unreadable reading: a comparison against a pre-state nobody captured proves nothing.
    """
    if op not in OPS:
        raise ValueError(f"unknown operator {op!r}")
    needs_operand, test = OPS[op]
    if isinstance(actual, Unreadable):
        return UNREADABLE, actual.reason
    if needs_operand:
        if operand is None:
            raise ValueError(f"{op} needs an operand")
        if isinstance(operand, Unreadable):
            return UNREADABLE, f"operand: {operand.reason}"
        shown = f"{_show(actual.value)} {op} {_show(operand.value)}"
        why = absence(op, actual.value, operand.value)
        if why:
            return UNREADABLE, f"{shown}: {why}"
        ok = test(actual.value, operand.value)
    else:
        ok = test(actual.value, None)
        shown = f"{_show(actual.value)} {op}"
    return (PASS if ok else FAIL), shown


def _show(value) -> str:
    """For the report line only. Verdicts never read this, so shortening it cannot change one."""
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= 120 else text[:117] + "..."
