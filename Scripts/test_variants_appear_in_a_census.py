#!/usr/bin/env python3
"""Prove `Scripts/check-variants-appear-in-a-census.py` finds the thing it exists for, and does
not find the things it must not.

The guard's whole value is the near-miss list — a string somebody typed instead of read, close to
one Logic really shows. `playheadPositionGroupLabel` carried `再生ヘッド位置` for as long as it had
existed, Logic shows `再生ヘッドの位置`, and no check in this repository could say so. These cases
plant that shape and three ways of being wrong about it.
"""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nearmiss", HERE / "check-variants-appear-in-a-census.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

failures, ran = [], [0]


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


# --- locale_of: the script decides the column, and refuses when it cannot -------------------
case("hangul is ko", guard.locale_of("트랙 콘텐츠") == "ko-KR")
case("kana is ja", guard.locale_of("トラックコンテンツ") == "ja-JP")
case("kanji is ja", guard.locale_of("再生ヘッドの位置") == "ja-JP")
case("ascii is en", guard.locale_of("Tracks contents") == "en-US")
# A mixed string pins to the script that is present; a string with no script signal pins to none.
case("a string with no letters pins to nothing", guard.locale_of("…") is None,
     repr(guard.locale_of("…")))
case("an empty string pins to nothing", guard.locale_of("") is None)


# --- the near-miss itself -------------------------------------------------------------------
def ledger(rows, labels):
    """A temp repo whose evidence directory holds one census and whose projection holds `labels`."""
    root = Path(tempfile.mkdtemp())
    (root / "docs" / "observations" / "evidence").mkdir(parents=True)
    (root / "docs" / "locale").mkdir(parents=True)
    (root / "docs" / "observations" / "evidence" / "x.census.json").write_text(
        json.dumps({"host": {"locale": "ja-JP"}, "census": rows}, ensure_ascii=False),
        encoding="utf-8")
    (root / "docs" / "locale" / "ui-labels.json").write_text(
        json.dumps({"labels": labels}, ensure_ascii=False), encoding="utf-8")
    guard.OBS = str(root / "docs" / "observations")
    guard.LABELS = str(root / "docs" / "locale" / "ui-labels.json")
    return root


SHOWN = [{"role": "AXGroup", "description": "再生ヘッドの位置"}]
UNMEASURED = {"en-US": "unmeasured", "ko-KR": "unmeasured", "ja-JP": "unmeasured"}


def run(labels, rows=SHOWN):
    ledger(rows, labels)
    import io as _io
    import contextlib
    buf = _io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = guard.main()
    return rc, buf.getvalue()


rc, out = run({"playheadPositionGroupLabel": {
    "canonical": "playhead position", "variants": ["再生ヘッド位置"], "coverage": dict(UNMEASURED)}})
case("the one-character miss is reported", "再生ヘッド位置" in out and "NEAR" in out, out)
case("and the string Logic shows is named beside it", "再生ヘッドの位置" in out, out)
case("reporting is not failing", rc == 0, rc)

rc, out = run({"playheadPositionGroupLabel": {
    "canonical": "playhead position", "variants": ["再生ヘッドの位置"], "coverage": dict(UNMEASURED)}})
case("a variant Logic DOES show is not a near miss", "NEAR" not in out, out)

rc, out = run({"somethingElse": {
    "canonical": "x", "variants": ["まったく無関係な文字列"], "coverage": dict(UNMEASURED)}})
case("a string with no near neighbour is absent but not NEAR", "NEAR" not in out, out)
case("...and is still counted as absent", "1 variant(s) absent" in out, out)

rc, out = run({"playheadPositionGroupLabel": {
    "canonical": "playhead position", "variants": ["再生ヘッド位置"],
    "coverage": dict(UNMEASURED, **{"ja-JP": "measured"})}})
case("a label the ledger already measured in that locale is skipped", "NEAR" not in out, out)

# A file that is not a census must not count as one. Without row shape, any JSON with a
# `host.locale` and a list called `census` was evidence — so a file holding one bare description
# made a genuinely absent variant look present and silenced a real near miss.
rc, out = run({"playheadPositionGroupLabel": {
    "canonical": "playhead position", "variants": ["再生ヘッド位置"], "coverage": dict(UNMEASURED)}},
    rows=[{"description": "再生ヘッド位置"}])
# A census of nothing but unshaped rows yields an EMPTY vocabulary, so the guard refuses outright
# rather than reporting a clean run — which is stronger than counting the variant as absent.
case("a row with no role is not a reading", rc == 1 and "refusing" in out, (rc, out))

# ...and a row that IS shaped still counts, so the rule narrows rather than breaks the guard.
rc, out = run({"playheadPositionGroupLabel": {
    "canonical": "playhead position", "variants": ["再生ヘッドの位置"], "coverage": dict(UNMEASURED)}},
    rows=[{"role": "AXGroup", "description": "再生ヘッドの位置"}])
case("a row with a role and an attribute is a reading", "0 variant(s) absent" in out, out)

# The AFFIX signal, and the five real defects it is shaped for. Every one of them is a string that
# lost a leading or trailing word when Logic 12.3 dropped the Show/Hide verb, and NONE of them
# scored high enough for the similarity cutoff — `Show Mixer` against `Mixer` is 0.72. That one was
# found by a unit-test fixture failing on its neighbour, which is not a method.
for shown, observed in [
    ("Show Mixer", "Mixer"),
    ("Show Step Input Keyboard", "Step Input Keyboard"),
    ("Hide All Plug-in Windows", "All Plug-in Windows"),
    ("모든 플러그인 윈도우 가리기", "모든 플러그인 윈도우"),
    ("스텝 입력 키보드 보기", "스텝 입력 키보드"),
]:
    case(f"affix finds {observed!r} for {shown!r}",
         guard._affix_of(shown, {observed, "Untitled"}) == observed,
         guard._affix_of(shown, {observed, "Untitled"}))

# The short tail, which a length ratio suppressed. Raised by review 2026-09-05.
case("affix finds a two-character tail", guard._affix_of("Show EQ", {"EQ"}) == "EQ",
     guard._affix_of("Show EQ", {"EQ"}))

# ...and the DIRECTION, which is what makes it a dropped-word signal rather than substring noise.
# The policy string must be the longer one, because Logic dropped a word the policy still carries.
case("affix does not report an unrelated LONGER menu command",
     guard._affix_of("Create", {"Create Group"}) is None,
     guard._affix_of("Create", {"Create Group"}))
case("affix ignores a short label inside a long unrelated title",
     guard._affix_of("Length", {"Move Locators Forward by Cycle Length"}) is None,
     guard._affix_of("Length", {"Move Locators Forward by Cycle Length"}))
case("affix ignores a chunk that is several words",
     guard._affix_of("Stop and Go to Last Locate Position", {"Position"}) is None,
     guard._affix_of("Stop and Go to Last Locate Position", {"Position"}))

# A containment label is not absent because no string EQUALS it — Logic showing it inside a longer
# value is a match for that label. Testing absence by equality regardless of mode reported fifty
# such rows as gaps.
case("a contains-label seen inside a longer value is not absent",
     guard._carries("send button", "send", "contains"), "")
case("...and an exact-label is not satisfied by the same thing",
     not guard._carries("send button", "send", "exact"), "")

# An empty vocabulary must not read as clean: the guard refuses rather than reporting no drift.
ledger([], {})
import io as _io
import contextlib
buf = _io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = guard.main()
case("no census at all is a refusal, not a pass", rc == 1, (rc, buf.getvalue()))

if failures:
    for f in failures:
        print(f"FAIL {f}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: a near miss is a string close to one Logic shows, and absence "
      f"without a neighbour is only absence")
