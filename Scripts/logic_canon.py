#!/usr/bin/env python3
"""Read Logic's own shipped data as the source of truth, and make a citation of it checkable offline.

WHY THIS EXISTS
---------------
This repository matched Logic's UI by carrying its own copies of Logic's strings -- one set per
locale, hand-typed, and wrong in ways nothing could see. `playheadPositionGroupLabel` carried
`再生ヘッド位置` for as long as it existed; Logic shows `再生ヘッドの位置`; one missing character
made the element unfindable on every Japanese Logic and the ledger read it as coverage.

Logic ships the answer. `QuickHelp.plist` holds 9,835 entries in ten locales with identical key
sets; every framework carries `Localizable.strings`; MADSP carries a parameter table per plug-in;
nibs carry the English of every screen. A string we type is a guess. A string we resolve from
those files is Apple's own, and the key that addresses it is the same in every locale.

So the rule this module exists to enforce: **a fact about Logic is cited from Logic's data, and a
fact that cannot be is proved uncitable before anyone is allowed to measure it by hand.**

THE CONSTRAINT THAT SHAPES EVERYTHING HERE
------------------------------------------
CI has no Logic installed -- `docs/observations/LOGIC-BUILD.json` says so, and that is why the
build there is declared rather than detected. A checker that needs the application can only run on
a developer's machine, which makes it advice. So this module splits in two:

    build time (needs Logic)      extract -> digest -> commit an index under docs/canon/
    check time (needs nothing)    resolve a citation against that committed index

The index carries keys and digests, never Apple's text. That keeps the repository free of
redistributed strings while still letting an offline checker answer both questions it must:

    "does this citation resolve, and is the quoted value the value Logic ships?"   -> index lookup
    "is this string absent from the corpus, so a measurement is the only route?"   -> absence set

THE ABSENCE SET, AND WHY IT IS SHAPED THIS WAY
----------------------------------------------
Proving presence needs one entry. Proving ABSENCE needs the whole corpus, which is the expensive
direction and the one people skip -- "I looked and it wasn't there" is not a proof anyone can
re-run. So `build` writes, per source and locale, the sorted 32-bit prefixes of the SHA-256 of
every normalized value it saw. An offline checker binary-searches it.

A 32-bit prefix collides. That is deliberate and it fails in the safe direction: a collision makes
an absent string look PRESENT, which refuses an absence claim and sends a person back to a machine
with Logic on it. It can never make a present string look absent, which would let a hand-typed
string masquerade as unciteable. The rate is stated rather than hidden -- `absence_false_positive`
reports it from the real entry count.

THE DECODING TRAP, WHICH COST A DAY
-----------------------------------
`.strings` files in this bundle are UTF-16, UTF-8, or Apple binary plists, and 861 are the last.
Decoding a UTF-8 file as UTF-16 raises nothing: the byte length is even, every pair is a valid code
unit, and the result is mojibake that yields zero parsed entries. A parser that "found nothing"
looks exactly like a file with nothing in it. `Carlton.strings` was reported empty this way; it
holds 940 entries.

So `decode_bytes` decides by magic and BOM before it decodes anything, tries UTF-8 BEFORE UTF-16
when there is no BOM, and returns None rather than a damaged string. Nothing in this module treats
"zero entries" as a fact -- `parse_strings` raises `CanonDecodeError` instead.
"""
from __future__ import annotations

import argparse
import binascii
import bisect
import collections
import glob
import hashlib
import json
import os
import plistlib
import re
import struct
import sys
import unicodedata
import urllib.parse
from functools import lru_cache

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANON_DIR = os.path.join(REPO, "docs", "canon")
DEFAULT_APP = "/Applications/Logic Pro.app"

#: Bumped when extraction or normalization changes in a way that moves a digest. The manifest
#: records it, and a checker refuses an index built by a different one rather than comparing
#: digests that were never comparable.
EXTRACTOR_VERSION = 2

#: The ten locale names Logic ships QuickHelp under. `build` verifies this list against the bundle
#: and fails when it disagrees, because a locale appearing or vanishing is exactly the kind of
#: drift that should stop a build rather than shrink a corpus quietly.
EXPECTED_LOCALES = ("de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh_CN", "zh_TW")

#: Ten NAMES, seven FILES. `en.lproj`, `it.lproj`, `pt.lproj` and `zh_TW.lproj` ship the same
#: QuickHelp.plist byte for byte (sha256 3ed7aa22...), so it, pt and zh_TW are untranslated English.
#: This matters twice. A claim that something "holds across ten locales" counts three agreements
#: that are true by construction -- an earlier revision of the AXHelp record said exactly that, and
#: the number was right while the sentence overstated its own independence. And a user running
#: Logic in Italian sees Italian on screen while this table holds English, so any AXHelp read on
#: those systems may not match at all. Nothing here has measured that.
QUICKHELP_LOCALE_ALIASES = {"it": "en", "pt": "en", "zh_TW": "en"}

#: How confident we are that `f"{Title}. {Text}"` is the join Logic actually performs, per locale.
#:
#:   measured        ko -- 86 of 86 live AXHelp values carried exactly this composition as a suffix
#:   consistent      the locale's punctuation statistics fit a ". " join; no live reading
#:   inconsistent    the statistics ARGUE AGAINST it; composing anyway would manufacture a string
#:
#: The two `inconsistent` locales are not a guess either. In zh_CN 5,980 of 9,835 Titles end in a
#: FULLWIDTH COLON, so the join produces `"…旋钮和栏：. 调整…"` -- a colon and a full stop doing the
#: same job, which no shipped interface writes. In ja 9,754 of 9,835 Texts end in `。` while the
#: join inserts an ASCII full stop. Both were extrapolated from ko in the first revision of this
#: module, which is the error this table exists to stop repeating.
LOCALE_JOIN_CONFIDENCE = {
    "ko": "measured",
    "de": "consistent", "en": "consistent", "es": "consistent", "fr": "consistent",
    "it": "consistent", "pt": "consistent", "zh_TW": "consistent",
    "ja": "inconsistent", "zh_CN": "inconsistent",
}


class CanonError(Exception):
    """Base for every refusal in this module. Never raised directly."""


class CanonDecodeError(CanonError):
    """A file could not be decoded. Raised instead of returning an empty parse.

    This exists because the failure it names is invisible: mojibake parses to zero entries and
    zero entries is a plausible file. Callers must not be able to mistake one for the other.
    """


class CanonRefError(CanonError):
    """A citation string is not a well-formed canonical reference."""


class CanonResolveError(CanonError):
    """A well-formed citation did not resolve against the committed index."""


# ---------------------------------------------------------------------------
# normalization and digests
# ---------------------------------------------------------------------------

#: NBSP is the reason this function is not `str.strip()`. Logic writes U+00A0 inside product names
#: -- `Logic Pro`, `Smart Controls`, `Live Loop` -- and it is invisible in every
#: terminal and every diff. Two strings that look identical on screen hash differently, so a
#: citation typed by eye would never match a value read from the bundle. Folding it here makes the
#: comparison the one a human means. NFC follows because the same text reaches us decomposed from
#: some files and composed from others.
_NBSP = " "


def normalize(text: str) -> str:
    """Fold a string to the form every digest and every comparison in this module is taken over."""
    if text is None:
        raise CanonError("normalize() received None; a missing value is not an empty one")
    # Deliberately NOT collapsing runs of spaces. An earlier revision did, to make a re-flowed
    # value still match, and the round-trip test caught what that cost: Logic separates a control's
    # title from its key equivalent with THREE spaces -- `재생   ⌅, 재생 버튼. …` -- and collapsing
    # them rewrote the runtime prefix the parser is supposed to hand back untouched. 1,765 of
    # 7,058 compositions failed to round trip for that reason alone. A fold nobody measured a need
    # for is a fold that only loses information.
    # `strip()` is the half of this fold nobody documented, and it is NOT the same trade as the
    # NBSP fold. Folding NBSP makes a human-typed citation match a string Logic writes with an
    # invisible character; stripping MERGES two values Apple ships as genuinely different table
    # entries. Measured 2026-09-15 across the `.strings` corpus: 601 normalized forms are reached
    # by more than one raw value, 338 through NBSP and 263 through `strip()` alone -- `'Bass'` and
    # `' Bass'`, `'Pan'` and `'Pan '`. Within one source and locale that means one key's digest can
    # satisfy a quote belonging to another, and an absence claim for `' Bass'` is refuted by the
    # presence of `'Bass'`. Kept, because a citation typed by eye cannot carry leading whitespace
    # and refusing it would reject honest quotes; recorded, because the cost was not stated before.
    return unicodedata.normalize("NFC", text).replace(_NBSP, " ").strip()


def digest(text: str) -> str:
    """The full SHA-256 of the normalized text, hex. What a citation quotes."""
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()


#: Characters a UI adds or drops around a label without changing which label it is: the colon a
#: form puts after a field name, the ellipsis a menu puts on an item that opens a dialog, spaces.
#: Folding them answers a DIFFERENT question from `normalize`, and only one question: "is this
#: absent, or is it a shipped label I typed slightly wrong?"
_DECORATION = "\u2026...:：·•\t\n\r \u00a0\u3000-–—_"


def fold_for_near_miss(text: str) -> str:
    """`normalize`, with decoration and whitespace removed. Case is kept; see below.

    NOT a canon comparison and never used as one. `absent` proves a BYTE STRING is not in the
    corpus, and that is exactly true and quietly useless on its own: `Input Port:` is absent and
    `Input Port` is shipped, so adding a colon proves anything uncitable. Three literals on the
    control-surface branch were proved absent across all 24 corpora that way, and none of them had
    ever been read off a screen -- the observation record mentions `Input Port` zero times.

    So the corpus gets a second digest set over this fold, and `absent` answers "not in the corpus,
    and nothing in the corpus differs from it only by decoration" instead of just the first half.
    """
    # NOT case-folded, deliberately. Runtime matching IS case-insensitive -- `caseInsensitiveCompare`
    # in `LabelSet.matches` -- so `Go To Position` against Logic's `Go to Position` still matches on
    # screen and is not the defect this looks for. Folding case here made it fire on that pair and
    # on every lowercase containment fragment (`arm` beside a French `Arm`), 33 findings of which
    # three were real. Decoration only.
    # Format characters (Unicode category Cf) fold too, and they are not in `_DECORATION` because
    # naming them one by one is the shape that misses the next one. A ZERO WIDTH SPACE, a soft
    # hyphen, a word joiner or a BOM inside a label is INVISIBLE ON SCREEN -- so a reading that
    # carries one cannot have been read off a screen as a different string, and `Mix\u200ber`
    # proving "absent" for `Mixer` is the near miss this fold exists to catch. A review used
    # exactly that spelling to pass an absence claim for a label Logic ships.
    return "".join(ch for ch in normalize(text)
                   if ch not in _DECORATION and unicodedata.category(ch) != "Cf")


def fold_case(text: str) -> str:
    """`normalize`, then Unicode case folding. The comparison a LabelSet makes, and only that.

    Every match mode the ledger certifies ignores case: `caseInsensitiveCompare` for `exact` and
    `exact_strict`, `.caseInsensitive` for `prefix` and `contains`. Measured 2026-09-25 against
    Foundation on this Mac: `caseInsensitiveCompare` agrees with `str.casefold` on `straße`/`STRASSE`,
    a final sigma and the `fi` ligature, where `str.lower` does not. So asking the corpus "does Apple
    ship this, as the product would match it" means folding both sides this way.

    It is not `fold_for_near_miss`. That one keeps case and drops decoration, because it answers
    whether an ABSENCE claim is a typo; this one keeps decoration and drops case, because it answers
    whether a MEMBER is a string Apple ships. `Mixer:` is still not `mixer`.
    """
    return normalize(text).casefold()


def short_digest(text: str) -> str:
    """The first 12 hex characters of `digest`. What the committed index stores.

    Twelve hex is 48 bits. Against the largest single index this repository builds the chance of
    any collision is far below the chance of the file being wrong for an ordinary reason, and the
    index is a lookup by key -- a collision would have to land on the one key being checked, not
    anywhere in the corpus. The absence set is the structure where collisions matter, and it
    states its own rate.
    """
    return digest(text)[:12]


def _u32(text: str) -> int:
    """The first 32 bits of the digest, as an int. The absence set's element type."""
    return int(digest(text)[:8], 16)


def absence_false_positive(entries: int) -> float:
    """The chance one absent string looks present in a 32-bit set holding `entries` values."""
    return 0.0 if entries <= 0 else min(1.0, entries / 2.0 ** 32)


# ---------------------------------------------------------------------------
# decoding -- the trap documented in the module docstring
# ---------------------------------------------------------------------------

_BOM_UTF16 = (b"\xff\xfe", b"\xfe\xff")
_BPLIST = b"bplist00"


def looks_binary_plist(raw: bytes) -> bool:
    return raw[:8] == _BPLIST


def decode_bytes(raw: bytes) -> str | None:
    """Decode text that may be UTF-16 (with BOM), UTF-8, or UTF-16 without a BOM.

    Returns None when no encoding produces a clean decode. Never returns a damaged string, which
    is the whole point: `raw.decode("utf-16")` succeeds on UTF-8 input and yields mojibake.

    Order matters. A BOM is authoritative and is honoured first. Without one, UTF-8 is tried
    BEFORE UTF-16, because UTF-8 text rarely decodes as UTF-16 without error while the reverse
    happens constantly -- any even-length byte string is valid UTF-16LE.
    """
    if raw[:2] in _BOM_UTF16:
        try:
            return raw.decode("utf-16")
        except UnicodeDecodeError:
            return None
    if raw[:3] == b"\xef\xbb\xbf":
        try:
            return raw[3:].decode("utf-8")
        except UnicodeDecodeError:
            return None
    for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
        try:
            text = raw.decode(encoding)
        except UnicodeDecodeError:
            continue
        # A UTF-16 decode of UTF-8 bytes produces CJK-range noise and, very often, a NUL. Refuse
        # anything carrying a NUL: no .strings file in this bundle legitimately contains one, and
        # it is the cheapest signal that the encoding guess was wrong.
        if "\x00" in text:
            continue
        return text
    return None


# ---------------------------------------------------------------------------
# the .strings parser
# ---------------------------------------------------------------------------

#: `\0` is deliberately NOT here: it is handled by the octal branch, which reads `\0`, `\00` and
#: `\000` the way CFPropertyList does. A lowercase `\u` is also absent -- CFPropertyList treats it
#: as a literal `u`, and an earlier version decoded it as a code point, which is the opposite of
#: what Apple's parser does.
_ESCAPES = {
    '"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r",
    "a": "\a", "b": "\b", "f": "\f", "v": "\v", "'": "'",
}


def _scan_quoted(text: str, i: int) -> tuple[str, int]:
    """Read one double-quoted string starting at `text[i] == '"'`. Returns (value, next index).

    Written as a scanner rather than a regular expression because the regular expression that
    "works" on this format -- `"((?:[^"\\]|\\.)*)"` -- silently drops the escape handling that
    makes `\\U` sequences readable, and Logic's files use them. A value containing an escaped
    quote is common enough that getting it wrong would corrupt real entries rather than fail.
    """
    if text[i] != '"':
        raise CanonDecodeError(f"expected a quote at offset {i}")
    out: list[str] = []
    i += 1
    while i < len(text):
        ch = text[i]
        if ch == '"':
            return "".join(out), i + 1
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(text):
            raise CanonDecodeError("string ends inside an escape sequence")
        esc = text[i]
        if esc == "U":
            hex4 = text[i + 1:i + 5]
            if len(hex4) < 4 or any(c not in "0123456789abcdefABCDEF" for c in hex4):
                raise CanonDecodeError(f"malformed \\U escape at offset {i}")
            code = int(hex4, 16)
            i += 5
            # A SURROGATE PAIR. CFPropertyList joins them; the first version emitted two lone
            # surrogates instead, so `\U D83D \U DE00` became garbage rather than an emoji -- and
            # `digest()` hashes the garbage without raising, so a wrong digest would be committed
            # with no signal at all. No string in this Logic uses one, which is why the corpus
            # comparison against `plutil` was clean over all 2,538 files and this stayed latent.
            # Found by review 2026-09-15. It goes live on the first Logic that ships an emoji.
            if 0xD800 <= code <= 0xDBFF and text[i:i + 2] == "\\U":
                low = text[i + 2:i + 6]
                if len(low) == 4 and all(c in "0123456789abcdefABCDEF" for c in low):
                    trail = int(low, 16)
                    if 0xDC00 <= trail <= 0xDFFF:
                        out.append(chr(0x10000 + ((code - 0xD800) << 10) + (trail - 0xDC00)))
                        i += 6
                        continue
            out.append(chr(code))
            continue
        if esc.isdigit():
            # An OCTAL escape, which CFPropertyList reads and the first version passed through as
            # its own digits: `\101` became `101` rather than `A`. Also latent in this build.
            digits = ""
            while len(digits) < 3 and i < len(text) and text[i] in "01234567":
                digits += text[i]
                i += 1
            if digits:
                out.append(chr(int(digits, 8)))
                continue
        if esc in _ESCAPES:
            out.append(_ESCAPES[esc])
            i += 1
            continue
        # An unknown escape is the character itself, which is what CFPropertyList does.
        out.append(esc)
        i += 1
    raise CanonDecodeError("unterminated string")


def _skip_trivia(text: str, i: int) -> int:
    """Advance past whitespace and both comment forms."""
    while i < len(text):
        ch = text[i]
        if ch.isspace():
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end + 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                raise CanonDecodeError("unterminated block comment")
            i = end + 2
            continue
        return i
    return i


def parse_strings(raw: bytes, *, path: str = "<bytes>") -> dict[str, str]:
    """Parse a `.strings` file, whichever of its three forms it is in.

    Raises `CanonDecodeError` rather than returning `{}` when the bytes cannot be decoded. An
    empty dict from this function means the file really is empty; that distinction is the reason
    the function exists.
    """
    if looks_binary_plist(raw):
        try:
            loaded = plistlib.loads(raw)
        except Exception as exc:  # plistlib raises several unrelated types
            raise CanonDecodeError(f"{path}: binary plist did not load: {exc}") from exc
        if not isinstance(loaded, dict):
            raise CanonDecodeError(f"{path}: binary plist is {type(loaded).__name__}, not a dict")
        return {str(k): str(v) for k, v in loaded.items()}

    if raw.lstrip()[:5] == b"<?xml" or raw.lstrip()[:9] == b"<!DOCTYPE":
        try:
            loaded = plistlib.loads(raw)
        except Exception as exc:
            raise CanonDecodeError(f"{path}: xml plist did not load: {exc}") from exc
        if not isinstance(loaded, dict):
            raise CanonDecodeError(f"{path}: xml plist is {type(loaded).__name__}, not a dict")
        return {str(k): str(v) for k, v in loaded.items()}

    text = decode_bytes(raw)
    if text is None:
        raise CanonDecodeError(f"{path}: no encoding decoded these bytes cleanly")

    out: dict[str, str] = {}
    i = _skip_trivia(text, 0)
    while i < len(text):
        if text[i] == '"':
            key, i = _scan_quoted(text, i)
        else:
            start = i
            while i < len(text) and (text[i].isalnum() or text[i] in "_.-"):
                i += 1
            if i == start:
                raise CanonDecodeError(f"{path}: unexpected {text[i]!r} at offset {i}")
            key = text[start:i]
        i = _skip_trivia(text, i)
        if i >= len(text) or text[i] != "=":
            raise CanonDecodeError(f"{path}: expected '=' after key {key!r}")
        i = _skip_trivia(text, i + 1)
        if i >= len(text):
            raise CanonDecodeError(f"{path}: file ends after '=' for key {key!r}")
        if text[i] == '"':
            value, i = _scan_quoted(text, i)
        else:
            start = i
            while i < len(text) and text[i] not in ";\n":
                i += 1
            value = text[start:i].strip()
        i = _skip_trivia(text, i)
        if i < len(text) and text[i] == ";":
            i += 1
        out[key] = value
        i = _skip_trivia(text, i)
    return out


def load_plist(path: str):
    with open(path, "rb") as handle:
        return plistlib.load(handle)


# ---------------------------------------------------------------------------
# canonical references
# ---------------------------------------------------------------------------

#: The citation grammar. One shape for every source, so a checker never needs to know which source
#: it is looking at to decide whether a string is well formed:
#:
#:     logic-canon://<source>/<unit>/<locale>/<key>#<field>
#:
#: `unit` is the file or plug-in the key lives in, `-` for a source that has one flat namespace.
#: `locale` is `-` for data Logic does not localise. `key` and `unit` are percent-encoded, because
#: real keys contain `/` (`Region starts at %@ and ends at %@` does not, but nib paths do) and `#`.
_REF_RE = re.compile(
    r"^logic-canon://(?P<source>[a-z0-9_-]+)/(?P<unit>[^/]+)/(?P<locale>[^/]+)/(?P<key>[^#]+)#(?P<field>[A-Za-z0-9_]+)$"
)

#: `logic-canon://<source>/<locale>#value` -- a VALUE citation, with no key in it.
#:
#: The key is where the last human judgement lived. `추가` is the value of `Add` and of
#: `Label_For_Drummer_Editor_GhostNotes_Slider|||More`; both resolve, both pass every check, and
#: only one MEANS what a change is about. 227 of this repository's literals are `.strings` values
#: and only 63 have a unique key, so the other 164 asked somebody to choose, every time, with
#: nothing mechanical to check the choice against.
#:
#: They should not have been asked. A `LabelSet` matches Logic at runtime BY VALUE -- it never sees
#: a key -- so a key citation asserts more than the code relies on, and the surplus is exactly the
#: part no check can verify. A value citation asserts what is actually used: Apple ships this
#: string, in this corpus, in this locale.
_VALUE_REF_RE = re.compile(
    r"^logic-canon://(?P<source>[a-z0-9_-]+)/(?P<locale>[^/#]+)#(?P<field>value)$"
)

SCHEME = "logic-canon"


#: A reference must contain no whitespace. `find_refs` scans prose with `\S+?`, so a space inside a
#: reference truncates it silently -- the scan returns a shorter string that still parses, resolves
#: to nothing, and reports a missing key rather than a malformed one. Real keys contain spaces
#: constantly (`Show/Hide Automation`, `Display %@ Channel Strips`), so this is not an edge case.
_REF_SAFE = "._~-"


def _pct_encode(text: str) -> str:
    out = []
    for ch in text:
        if ch.isalnum() and ch.isascii() or ch in _REF_SAFE:
            out.append(ch)
        else:
            out.extend(f"%{b:02X}" for b in ch.encode("utf-8"))
    return "".join(out)


#: A `%` that does not begin a two-hex-digit escape. One pass finds both shapes the byte loop
#: below used to find separately: a truncated escape at the end, and a bad one anywhere.
_BAD_ESCAPE = re.compile("%(?![0-9A-Fa-f]{2})")


@lru_cache(maxsize=1 << 16)
def _pct_decode(text: str) -> str:
    """Decode a reference component, REFUSING anything `_pct_encode` would not have produced.

    A bare `%` is refused rather than passed through. Passing it made decoding NON-INJECTIVE --
    `100%` and `100%25` both decoded to `100%` -- so two different reference strings named one key.
    `_pct_encode` never emits a bare `%`, so this can only reach a hand-written reference, which is
    exactly where a silent alias is worst. `urllib.parse.unquote` passes a bare `%` through, which
    is why the validation above it is not optional: the C-speed decoder is used only after this
    function has established there is nothing for it to be lenient about.

    Why it is written this way: measured 2026-09-18, the byte-at-a-time loop this replaces was
    2,429,828 calls and 94% of `check-canon-citations.py`'s 13.5s -- 107 million `bytearray.extend`
    calls, one per character of every unit and key in every index file, read 886 times. The guard's
    own self-test runs the guard ~60 times, which is how one hot loop became 9.4 minutes of every
    CI run, twice. The cache is here for the same reason: `load_index` decodes the same unit string
    once per row, and the distinct strings number in the thousands.
    """
    if "%" not in text:
        return text
    if _BAD_ESCAPE.search(text):
        if text.endswith("%") or len(text) - text.rfind("%") < 3:
            raise CanonRefError(f"truncated percent escape at the end of {text!r}")
        raise CanonRefError(f"bad percent escape in {text!r}")
    # `errors="strict"` so a non-UTF-8 escape sequence raises `UnicodeDecodeError`, which is what
    # the byte loop's final `bytearray.decode("utf-8")` raised. Deliberately NOT rewrapped as a
    # `CanonRefError`: rewrapping would be an improvement to an exception type that callers may be
    # catching, made as a side effect of a speed change, and one of those is not the other.
    return urllib.parse.unquote(text, errors="strict")


class CanonRef:
    """One canonical reference, parsed. Compared and hashed by its canonical string form."""

    __slots__ = ("source", "unit", "locale", "key", "field")

    def __init__(self, source: str, unit: str, locale: str, key: str, field: str):
        self.source, self.unit, self.locale, self.key, self.field = source, unit, locale, key, field

    @property
    def is_value_citation(self) -> bool:
        """No key: the claim is "Apple ships this string here", which is what a LabelSet uses."""
        return self.key == ""

    @classmethod
    def parse(cls, text: str) -> "CanonRef":
        text = text.strip()
        value_match = _VALUE_REF_RE.match(text)
        if value_match:
            return cls(value_match["source"], "", value_match["locale"], "", "value")
        match = _REF_RE.match(text)
        if not match:
            raise CanonRefError(
                f"not a canonical reference: {text!r}\n"
                f"  expected {SCHEME}://<source>/<unit>/<locale>/<key>#<field>\n"
                f"  or       {SCHEME}://<source>/<locale>#value  (no key -- Apple ships this string)"
            )
        return cls(
            match["source"],
            _pct_decode(match["unit"]),
            match["locale"],
            _pct_decode(match["key"]),
            match["field"],
        )

    def __str__(self) -> str:
        if self.is_value_citation:
            return f"{SCHEME}://{self.source}/{self.locale}#value"
        return (f"{SCHEME}://{self.source}/{_pct_encode(self.unit)}/{self.locale}/"
                f"{_pct_encode(self.key)}#{self.field}")

    def __eq__(self, other) -> bool:
        return isinstance(other, CanonRef) and str(self) == str(other)

    def __hash__(self) -> int:
        return hash(str(self))

    def index_row(self) -> tuple[str, str, str, str]:
        return (self.unit, self.locale, self.key, self.field)


def find_refs(text: str) -> list[str]:
    """Every canonical reference appearing anywhere in a blob of text.

    Used to scan issue bodies, pull request bodies, ADRs and tickets, which are prose and cannot be
    required to be JSON. Deliberately greedy about what it finds and strict about what it accepts:
    anything starting with the scheme is returned, and `CanonRef.parse` decides whether it is well
    formed. A malformed reference must surface as an error, not vanish from a scan.
    """
    found = re.findall(r"logic-canon://\S+?#[A-Za-z0-9_]+", text)
    # `<source>` and `<locale>` are how prose SHOWS the shape of a reference, and this scan was
    # greedy enough to take them for citations -- so a pull request body explaining the format was
    # refused for stating a malformed reference. `_pct_encode` escapes `<` and `>` to %3C and %3E,
    # so a real reference cannot contain either: an angle bracket is a placeholder, never a key.
    # The greed is deliberate everywhere else -- a malformed reference must surface as an error
    # rather than vanish -- and this is the one shape that is not one.
    return [ref for ref in found if "<" not in ref and ">" not in ref]


# ---------------------------------------------------------------------------
# extractors -- one per canonical source family
# ---------------------------------------------------------------------------
#
# Each yields rows of (unit, locale, key, field, value). `build` turns those into digests. An
# extractor never interprets: it reports what the file says, and the interpreting happens where it
# can be cited and argued with.

def _rel(app: str, path: str) -> str:
    return os.path.relpath(path, app)


def _locale_of(path: str) -> str | None:
    for part in path.split(os.sep):
        if part.endswith(".lproj"):
            name = part[: -len(".lproj")]
            return "en" if name == "Base" else name
    return None


def compose_quickhelp(title: str, text: str, locale: str | None = None) -> str:
    """The string Logic puts in AXHelp for an entry that has both a Title and a Text.

    Measured for ko -- see `docs/observations/2026-09-15-axhelp-is-quickhelp-composed.json`. On 86
    of 86 live containment matches this composition sat at the END of the AXHelp value, with a
    runtime prefix in front of it on 30 of them.

    `locale` is optional and carries no behaviour: the join is the same for every locale because
    nothing has measured a different one. What the locale is FOR is the caller's obligation to look
    at `LOCALE_JOIN_CONFIDENCE` before trusting the result -- ja and zh_CN are marked
    `inconsistent` there on the strength of their own punctuation, and a composition built for them
    is a hypothesis this function cannot refuse to produce but nobody should cite as Apple's text.
    """
    title, text = (title or "").strip(), (text or "").strip()
    if title and text:
        return normalize(f"{title}. {text}")
    return normalize(title or text)


def join_confidence(locale: str) -> str:
    return LOCALE_JOIN_CONFIDENCE.get(locale, "unknown")


def extract_quickhelp(app: str):
    resources = os.path.join(app, "Contents", "Resources")
    for entry in sorted(os.listdir(resources)):
        if not entry.endswith(".lproj"):
            continue
        locale = entry[: -len(".lproj")]
        for base in ("QuickHelp", "QuickHelpDefault"):
            path = os.path.join(resources, entry, f"{base}.plist")
            if not os.path.exists(path):
                continue
            loaded = load_plist(path)
            if not isinstance(loaded, dict):
                raise CanonDecodeError(f"{path}: expected a dict at the top level")
            for key, value in loaded.items():
                if not isinstance(value, dict):
                    continue
                local = value.get("_LOCALIZABLE_") or {}
                title, text = local.get("Title") or "", local.get("Text") or ""
                if title:
                    yield (base, locale, key, "Title", title)
                if text:
                    yield (base, locale, key, "Text", text)
                anchor = value.get("Anchor")
                if anchor:
                    yield (base, locale, key, "Anchor", str(anchor))
                composed = compose_quickhelp(title, text)
                if composed:
                    yield (base, locale, key, "composed", composed)


def extract_strings(app: str):
    """Every `.strings` file in the bundle, addressed by the framework path that holds it.

    The unit is the bundle-relative path of the `.lproj`'s parent joined with the file's basename,
    so `MAMixer.framework/.../Resources` + `Localizable.strings` addresses the table that holds
    `"audio plug-in"`. Two frameworks can both define a key; a flat namespace would let one answer
    for the other, which is precisely the mistake this whole module exists to stop.
    """
    for root, _dirs, files in os.walk(app):
        for name in sorted(files):
            if not name.endswith(".strings"):
                continue
            path = os.path.join(root, name)
            # A `.strings` file outside every `.lproj` is not localised, and it is still part of
            # the corpus. Dropping it was a hole in the ABSENCE direction, which is the direction
            # that cannot be checked by looking: `MAGFUserInterface.strings` holds 30 English
            # interface strings at a framework's Resources root, and any one of them would have
            # been proved "absent from Logic" while sitting in Logic. Found by review 2026-09-15.
            locale = _locale_of(path) or "-"
            with open(path, "rb") as handle:
                raw = handle.read()
            try:
                table = parse_strings(raw, path=path)
            except CanonDecodeError:
                # Reported by `build` as a named failure rather than swallowed. Re-raised there
                # with the path so a corpus is never quietly short.
                raise
            unit = os.path.join(_rel(app, os.path.dirname(os.path.dirname(path))), name)
            for key, value in table.items():
                yield (unit, locale, key, "value", value)


def extract_madsp(app: str):
    """MADSP's per-plug-in parameter tables. Not localised -- the names are fixed in the plist.

    Measured: the 130 plists sit at the framework's Resources root, in no `.lproj`, and the ten
    `Localizable.strings` beside them hold 23 error and side-chain strings with no parameter names
    in them. So `locale` is `-` here and that is a fact about the data, not a shortcut.
    """
    resources = os.path.join(
        app, "Contents", "Frameworks", "MADSP.framework", "Versions", "A", "Resources")
    if not os.path.isdir(resources):
        return
    skip = {"Info.plist", "version.plist"}
    for name in sorted(os.listdir(resources)):
        if not name.endswith(".plist") or name in skip:
            continue
        loaded = load_plist(os.path.join(resources, name))
        if not isinstance(loaded, list):
            continue
        unit = name[: -len(".plist")]
        for control in _walk_madsp(loaded):
            pid = control.get("parameterID")
            if pid is None:
                continue
            key = str(pid)
            if control.get("name"):
                yield (unit, "-", key, "name", str(control["name"]))
            if control.get("preferredControlType"):
                yield (unit, "-", key, "preferredControlType", str(control["preferredControlType"]))


def _walk_madsp(node):
    """Yield every leaf control dict, through all five container shapes the files actually use.

    The shapes are `sections`/`groups`/`parameters`/`pageName+sections`/`subGroupType+parameters`.
    A walker written against the two documented ones misclassified ES1, ES2, Sculpture, Vintage B3,
    Vintage Clav and Vintage Electric Piano as empty stubs -- six of the largest tables in the set.
    """
    if isinstance(node, list):
        for item in node:
            yield from _walk_madsp(item)
        return
    if not isinstance(node, dict):
        return
    nested = False
    for container in ("sections", "groups", "parameters"):
        if container in node:
            nested = True
            yield from _walk_madsp(node[container])
    for meta in ("onOffParameter", "activityValue"):
        if isinstance(node.get(meta), dict):
            yield node[meta]
    if not nested and ("parameterID" in node or "syncValueID" in node):
        yield node


def extract_nib_runtime_attributes(app: str):
    """`qhid` and its siblings, from the user-defined runtime attributes baked into every nib.

    Inverted on purpose: the KEY is the attribute's value (`ART_03_NameField`) and the value is the
    list of nibs carrying it, because the question worth asking is "which screen holds this
    control", not "what does this screen set".
    """
    sys.path.insert(0, os.path.join(REPO, "Scripts"))
    import nibarchive  # noqa: E402  -- resolved from Scripts/, which is this file's own directory

    found: dict[tuple[str, str], set[str]] = {}
    failures: list[str] = []
    for root, dirs, files in os.walk(app):
        # A bundle-style `.nib` is a DIRECTORY, and testing only `files` would skip it in silence
        # while `corpus_digest` -- which walks the same way -- would not notice the corpus had
        # shrunk. This build has none (1,169 files, 0 directories), so the check is a tripwire for
        # the next Apple packaging change rather than a fix for a present hole.
        for name in dirs:
            if name.endswith(".nib"):
                raise CanonDecodeError(
                    f"{_rel(app, os.path.join(root, name))} is a .nib DIRECTORY. This extractor "
                    f"reads files only, so the corpus would silently be short.")
        for name in sorted(files):
            if not name.endswith(".nib"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, "rb") as handle:
                    archive = nibarchive.parse(handle.read())
            except Exception as exc:
                failures.append(f"{_rel(app, path)}: {exc}")
                continue
            for key_path, value in nibarchive.runtime_attributes(archive):
                if isinstance(value, str) and value:
                    found.setdefault((key_path, value), set()).add(_rel(app, path))
    if failures:
        # Not swallowed. A nib that would not parse is a hole in the corpus, and a hole nobody is
        # told about is how an absence proof comes to be taken over a corpus that was short.
        raise CanonDecodeError(
            f"{len(failures)} nib(s) did not parse; first: {failures[0]}")
    for (key_path, value), paths in sorted(found.items()):
        yield (key_path, "-", value, "nibs", "\n".join(sorted(paths)))


def extract_nibstrings(app: str):
    """English, addressed by the SAME (unit, key) the translated `.strings` overlay already uses.

    Apple uses base internationalization: the English is compiled into `Base.lproj/<table>.nib` and
    only the translated locales get a `<locale>.lproj/<table>.strings` overlay. So a corpus that
    reads `.strings` alone has no English for those tables at all -- measured here: of the 162
    Base.lproj nibs that carry labels, ZERO have an `en.lproj/<table>.strings` beside them. An
    author citing the Korean succeeded and an author citing the English was told to prove a string
    Apple ships is uncitable. That is a false absence, and absence is the one direction this module
    must never be wrong about.

    The pairing is read from the archive's CLASSES, not guessed from what the strings look like:
    Interface Builder emits the English as an `NSLocalizableString` object and the `.strings` key
    for it as the NEXT object, an `NSString`. Measured over the whole bundle: 6,270 pairs from 162
    nibs with zero objects that did not follow the rule. Joined against the nine translated
    locales, 6,188 of 6,216 keys agree with the overlay and NOT ONE key is nib-only, so the unit
    here is the overlay's own address and a citation lands in the same table as its translations.

    The 28 keys the overlay has and the nib does not are the interface's numeric placeholders
    (`255`, `100`, `30.0`) and two literal `<PLACEHOLDER STRING: DO NOT LOCALIZE>` -- text
    Interface Builder holds for a field the running code fills in, not a label Apple shows.
    """
    sys.path.insert(0, os.path.join(REPO, "Scripts"))
    import nibarchive  # noqa: E402  -- resolved from Scripts/, which is this file's own directory

    failures: list[str] = []
    for root, dirs, files in os.walk(app):
        if os.path.basename(root) != "Base.lproj":
            continue
        for name in dirs:
            if name.endswith(".nib"):
                raise CanonDecodeError(
                    f"{_rel(app, os.path.join(root, name))} is a .nib DIRECTORY. This extractor "
                    f"reads files only, so the corpus would silently be short.")
        for name in sorted(files):
            if not name.endswith(".nib"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, "rb") as handle:
                    archive = nibarchive.parse(handle.read())
            except Exception as exc:
                failures.append(f"{_rel(app, path)}: {exc}")
                continue
            unit = os.path.join(
                _rel(app, os.path.dirname(os.path.dirname(path))),
                name[: -len(".nib")] + ".strings")
            for key, value in _nib_localizable_pairs(archive, _rel(app, path)):
                yield (unit, "en", key, "value", value)
    if failures:
        # Not swallowed, for the same reason the runtime-attribute extractor does not swallow: a
        # nib that would not parse is a hole in the corpus, and a hole nobody is told about is how
        # an absence proof comes to be taken over a corpus that was short.
        raise CanonDecodeError(f"{len(failures)} nib(s) did not parse; first: {failures[0]}")


def _nib_localizable_pairs(archive, rel_path: str):
    """Yield (key, english) for every `NSLocalizableString` in the archive, by the class rule.

    Raises rather than skipping when the object AFTER an `NSLocalizableString` is not the
    `NSString` holding its key. Skipping would drop English Apple ships and the corpus would then
    prove that string absent -- so a shape this reader does not understand stops the build.
    """
    import nibarchive  # noqa: E402

    classes = archive["classes"]
    objects = archive["objects"]
    texts = nibarchive.strings_by_object(archive)
    for index, obj in enumerate(objects):
        name = classes[obj["class"]] if obj["class"] < len(classes) else None
        if name != "NSLocalizableString":
            continue
        english = texts.get(index, {}).get("NS.bytes")
        following = objects[index + 1] if index + 1 < len(objects) else None
        next_class = (classes[following["class"]]
                      if following is not None and following["class"] < len(classes) else None)
        key = texts.get(index + 1, {}).get("NS.bytes") if following is not None else None
        if english is None or next_class != "NSString" or not key:
            raise CanonDecodeError(
                f"{rel_path} object {index} is an NSLocalizableString this reader cannot pair: "
                f"english={english!r} next_class={next_class!r} key={key!r}. The pairing is the "
                f"only thing that makes the English citable, so an unread one stops the build "
                f"rather than becoming an absence.")
        yield (key, english)


EXTRACTORS = {
    "quickhelp": extract_quickhelp,
    "strings": extract_strings,
    "madsp": extract_madsp,
    "nib": extract_nib_runtime_attributes,
    "nibstrings": extract_nibstrings,
}

#: The field suffix under which a cited row's CASE-FOLDED digest is pinned beside its exact one.
#:
#: The corpus proves exactly -- "does Apple ship this string" is a question about bytes, and folding
#: case would let `trim` claim to be `Trim`. The PRODUCT matches case-insensitively, in every
#: `LabelSet.matches` mode. A check that spans both needs to ask the product's question against the
#: corpus's data, and with only exact digests it cannot: `mixerNamedElement` carries the lowercase
#: `mixer` this product matches by containment, Apple's row says `Mixer`, and the two are the same
#: label to everything that runs. One extra digest per cited row, and only for cited rows.
CASE_INSENSITIVE = "#ci"


#: Sources that address the SAME (unit, key) and must be joined before asking whether Apple
#: translates an English string. `nibstrings` is the English column of `strings` -- Apple compiles
#: it into `Base.lproj/<table>.nib` instead of shipping `en.lproj/<table>.strings`, and measured on
#: this build not one of the 162 tables has both. Anything not listed here stands alone.
TRANSLATION_NAMESPACE = {"nibstrings": "strings"}


def locate_in(rows, text: str, *, source: str = "?"):
    """Every place `text` is a WHOLE value in `rows`, as citable (source, unit, locale, key, field).

    Separate from `AXStringResolver.resolve`, and the separation is the point. `resolve` reads
    `StringsIndex`, which holds 10,395 (unit, key) pairs for ko; `extract_strings` yields 60,048.
    So 83% of the corpus is invisible to it, and it answers None for a string Apple ships -- which
    an author reads as "uncitable" when a citation was available all along. Measured while
    preparing two pull requests: `설치` resolves to None and lives at
    `Install.strings/164.title` and `MAContentDownload.strings/73.title`; `키 레이블로 학습`
    resolves to None and lives at `KeyCommands.strings/300557.title`. Both had to be dug out of
    the extractor by hand.

    The narrow table is right for what it does -- reversing a live AXHelp reading, where a match
    in a content database would be noise. This is the other job: issuing a citation. It is a
    function over ROWS rather than over an app so it can be driven without Logic installed.

    The two references above, in the form this prints and `build` resolves. They live here rather
    than in `docs/canon/README.md` because that directory is this module's own output and is
    excluded from the citation scan, so a reference that lives only there is never resolved:

        logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FInstall.strings/ko/164.title#value
        logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FKeyCommands.strings/ko/300557.title#value
    """
    want = normalize(text)
    return [(source, unit, locale, key, field)
            for unit, locale, key, field, value in rows
            if normalize(value) == want]


def locate(app: str, text: str, *, sources=None, locales=None):
    """`locate_in` over the installed Logic, across every source. Needs Logic."""
    found = []
    for name in (sources or sorted(EXTRACTORS)):
        rows = EXTRACTORS[name](app)
        if locales:
            rows = (row for row in rows if row[1] in locales)
        found.extend(locate_in(rows, text, source=name))
    return found


def group_by_key(hits) -> list:
    """`locate` hits collapsed to one row per KEY: (source, unit, key, field, sorted locales).

    A key is the same in every locale, so an ungrouped answer repeats it once per locale --
    `Smart Controls` printed forty-odd lines, ten of them one QuickHelp key. Nobody chooses from
    that. Grouping restates the same answer in the shape #892 measured: pick a key once and the
    locales follow, 61 of 63 times.
    """
    groups: dict = {}
    for source, unit, locale, key, field in hits:
        groups.setdefault((source, unit, key, field), set()).add(locale)
    return [(source, unit, key, field, sorted(locales))
            for (source, unit, key, field), locales in sorted(groups.items())]


def citation_for(source: str, unit: str, locale: str, key: str, field: str) -> str:
    """The reference a `locate` hit becomes. One place builds these, so the encoding is one rule."""
    return (f"logic-canon://{source}/{_pct_encode(unit)}/{locale}"
            f"/{_pct_encode(key)}#{field}")


# ---------------------------------------------------------------------------
# the AXHelp parser
# ---------------------------------------------------------------------------

#: The shortest composition allowed to anchor a match. Set to 8 -- the corpus minimum -- so it
#: discards nothing. `logic_canon.py thresholds` prints what any other floor would cost.
#:
#: The floor was 12 in the first revision, on the reasoning that a short composition could appear
#: inside an unrelated AXHelp by coincidence. Raising it buys little and costs real coverage, and
#: what actually resolves the suffix-containment pairs is longest-match.
#:
#: The justification written here first carried four numbers and every one of them was wrong --
#: "128 real suffix pairs", "six of the seven", "5 of 11", "504 keys, 5.1%". Measured by review
#: 2026-09-15 and re-measured here: 65 pairs across the ten locale names, 47 across the seven
#: distinct files; a floor of 25 removes none in five of the seven, and in zh_CN it removes 4 of 7
#: at a cost of 1,533 of 7,031 compositions -- 21.8%, not 5.1%. The numbers are not restated in
#: this comment any more, because a number in a comment is a measurement nobody re-runs:
#: `logic_canon.py thresholds` and `logic_canon.py census` print them.
#:
#: So the floor stays only as a guard against a RUNTIME prefix -- text not in the corpus at all --
#: ending in a string that happens to be a whole short composition. Nothing has measured that risk.
DEFAULT_MIN_ANCHOR = 8


class AXHelpMatch:
    """What `parse_axhelp` returns. Every field is evidence, not a conclusion.

    `tier` is the part a caller must not ignore:

        exact      the whole value IS a QuickHelp composition; no runtime prefix
        suffix     a composition is the value's suffix; `prefix` is live runtime data
        truncated  the value is a PREFIX of a composition -- the reading was cut short

    `truncated` exists because AX dumps are routinely capped, and a capped reading that still
    identifies its key is worth keeping while being a weaker claim than a whole one. Collapsing it
    into `suffix` would let a truncation pass as a complete match.
    """

    __slots__ = ("tier", "prefix", "keys", "composed", "locale", "source_unit")

    def __init__(self, tier, prefix, keys, composed, locale, source_unit="QuickHelp"):
        self.tier, self.prefix, self.keys = tier, prefix, keys
        self.composed, self.locale, self.source_unit = composed, locale, source_unit

    @property
    def key(self) -> str | None:
        """The single key this value names, or None when the composition is shared.

        Returns None rather than the first of several. A composition shared by several keys is a
        real and common state -- 3,766 of 9,835 keys share their string with another in ko -- and
        picking one of them would manufacture a precision the data does not have.
        """
        return self.keys[0] if len(self.keys) == 1 else None

    def refs(self) -> list[str]:
        return [str(CanonRef(
            "quickhelp", self.source_unit, self.locale, key, "composed")) for key in self.keys]

    @property
    def join_confidence(self) -> str:
        """How far the composition this match rests on has actually been verified for its locale.

        Carried on every match rather than left to the caller to remember. A `inconsistent` match
        is still returned -- refusing would hide the locale entirely -- but it is labelled, so a
        consumer that treats ja like ko has to do so in writing.
        """
        return join_confidence(self.locale)

    def as_dict(self) -> dict:
        return {"tier": self.tier, "prefix": self.prefix, "keys": list(self.keys),
                "composed": self.composed, "locale": self.locale,
                "join_confidence": self.join_confidence, "refs": self.refs()}


class QuickHelpIndex:
    """Every QuickHelp composition for one locale, arranged so a suffix lookup is a dict hit.

    The algorithm matters. Scanning 9,835 compositions per value is what the first measurement did,
    and at that cost nobody runs it over a whole census. Instead: a value's suffixes are at most
    its own length, so walk the split points and ask the dict. That is O(len(value)) lookups
    against a corpus of any size, and it finds the LONGEST composition first because the walk
    starts at the front.
    """

    __slots__ = ("locale", "unit", "by_composed", "min_anchor", "_max_len")

    def __init__(self, locale: str, by_composed: dict[str, list[str]], *,
                 unit: str = "QuickHelp", min_anchor: int = DEFAULT_MIN_ANCHOR):
        self.locale, self.unit, self.min_anchor = locale, unit, min_anchor
        self.by_composed = by_composed
        self._max_len = max((len(c) for c in by_composed), default=0)

    @classmethod
    def from_app(cls, app: str, locale: str, *, unit: str = "QuickHelp",
                 min_anchor: int = DEFAULT_MIN_ANCHOR) -> "QuickHelpIndex":
        path = os.path.join(app, "Contents", "Resources", f"{locale}.lproj", f"{unit}.plist")
        loaded = load_plist(path)
        by_composed: dict[str, list[str]] = {}
        for key, value in loaded.items():
            if not isinstance(value, dict):
                continue
            local = value.get("_LOCALIZABLE_") or {}
            composed = compose_quickhelp(local.get("Title") or "", local.get("Text") or "")
            if composed:
                by_composed.setdefault(composed, []).append(key)
        for keys in by_composed.values():
            keys.sort()
        return cls(locale, by_composed, unit=unit, min_anchor=min_anchor)

    def parse_axhelp(self, value: str, *, allow_truncated: bool = True) -> AXHelpMatch | None:
        """Reverse one live AXHelp reading into the QuickHelp key or keys that composed it.

        Anchors on the SUFFIX and never splits on punctuation. Splitting on the comma is the
        obvious implementation and it is wrong: a runtime prefix contains commas and full stops of
        its own. The reading that settles it is a disabled control, whose AXHelp is

            '이 컨트롤을 사용할 수 없습니다. 원인: 오디오 트랙이 선택되지 않았습니다., 튜너 버튼. …'

        -- two sentences and a colon before the separator. Any split-based parser takes the first
        comma and returns a prefix that is a fragment of a sentence. Anchoring on a string the
        corpus actually contains cannot make that mistake: it either finds a composition or
        reports nothing.
        """
        folded = normalize(value)
        if not folded:
            return None

        # The anchor floor applies to the whole value too. Without this the floor guarded only
        # suffix matches, so a two-character AXHelp matched a two-character composition outright --
        # exactly the coincidence the floor exists to refuse.
        if len(folded) < self.min_anchor:
            return None

        # Tier 1 and 2 in one walk. `start` is where the composition would begin; start == 0 is a
        # whole-value match, anything else leaves a runtime prefix in front of it.
        for start in range(0, len(folded) - self.min_anchor + 1):
            candidate = folded[start:]
            keys = self.by_composed.get(candidate)
            if keys:
                prefix = folded[:start].rstrip()
                if prefix.endswith(","):
                    prefix = prefix[:-1].rstrip()
                return AXHelpMatch("exact" if start == 0 else "suffix",
                                   prefix, list(keys), candidate, self.locale, self.unit)

        # Tier 3: the reading was cut short, so no composition can be its suffix. Ask instead
        # whether the value -- or the value after some prefix -- is the START of exactly one
        # composition. Ambiguity here is refused rather than guessed: a truncated reading that
        # could belong to several keys identifies none of them.
        if not allow_truncated:
            return None

        # Every split point, not the first one that happens to be unique. Returning on the first
        # made the tier locally correct and globally wrong: a decoy composition beginning with
        # "<runtime prefix><head of the true one>" is matched at start=0, and the true source --
        # which would have matched at a later start -- is never reached. Demonstrated on a
        # constructed corpus by review 2026-09-15; not found in the shipped table, which makes it a
        # gap in the algorithm rather than a known-bad reading.
        found = []
        for start in range(0, len(folded) - self.min_anchor + 1):
            tail = folded[start:]
            hits = [(composed, keys) for composed, keys in self.by_composed.items()
                    if len(composed) > len(tail) and composed.startswith(tail)]
            if len(hits) == 1:
                found.append((start, hits[0][0], hits[0][1]))
            elif hits:
                # Ambiguous at this split point. A truncated reading that could belong to several
                # keys identifies none of them, and a longer prefix cannot rescue it.
                return None
        if len(found) != 1:
            return None
        start, composed, keys = found[0]
        prefix = folded[:start].rstrip()
        if prefix.endswith(","):
            prefix = prefix[:-1].rstrip()
        return AXHelpMatch("truncated", prefix, list(keys), composed, self.locale, self.unit)

    def suffix_collisions(self) -> list[tuple[str, str]]:
        """Compositions that are suffixes of other compositions, which is where longest-match can
        still name the wrong key. Reported so the number is known rather than assumed to be zero."""
        out = []
        for short in self.by_composed:
            if len(short) < self.min_anchor:
                continue
            for long in self.by_composed:
                if long is not short and len(long) > len(short) and long.endswith(short):
                    out.append((short, long))
        return out


# ---------------------------------------------------------------------------
# the committed index -- what makes an offline check possible
# ---------------------------------------------------------------------------

INDEX_DIR = os.path.join(CANON_DIR, "index")
ABSENCE_DIR = os.path.join(CANON_DIR, "absence")
MANIFEST_PATH = os.path.join(CANON_DIR, "MANIFEST.json")
SOURCES_PATH = os.path.join(CANON_DIR, "SOURCES.json")


def index_path(source: str) -> str:
    return os.path.join(INDEX_DIR, f"{source}.tsv")


def absence_path(source: str, locale: str) -> str:
    return os.path.join(ABSENCE_DIR, f"{source}.{locale}.u32")


def translated_path() -> str:
    """32-bit digests of every ENGLISH value Apple ships a different string for somewhere else.

    Committed for the same reason the absence sets are. "Does Apple translate this label" decides
    whether matching it by literal is a localisation bug, and CI has no Logic -- the first version
    of `check-ax-comparisons-use-labelsets.py` asked the bundle and therefore could not run in the
    one place the answer is needed.
    """
    return os.path.join(ABSENCE_DIR, "translated.en.u32")


def load_translated() -> list[int]:
    path = translated_path()
    if not os.path.exists(path):
        return []
    with open(path, "rb") as handle:
        blob = handle.read()
    if blob[:4] != b"LCA1":
        raise CanonError(f"{path}: not an LCA1 set")
    count = struct.unpack(">I", blob[4:8])[0]
    return list(struct.unpack(f">{count}I", blob[8:8 + count * 4]))


def is_translated(text: str) -> bool:
    """Whether Apple ships a different string for this English value in some other locale.

    A collision makes an UNtranslated string look translated, which asks an author to move a safe
    literal into a LabelSet -- work, not a wrong answer. The opposite would hide a real one, and
    the set is ordered so the cheap direction is the safe one, as everywhere else here.
    """
    table = load_translated()
    needle = _u32(normalize(text))
    position = bisect.bisect_left(table, needle)
    return position < len(table) and table[position] == needle


def value_index_path(source: str) -> str:
    """`locale <TAB> digest` for every VALUE something in this tree cites without a key.

    A separate file from the key index because the question is different, and it must NOT be the
    absence set: those are 32-bit prefixes whose collisions are safe in one direction only. A
    collision makes an ABSENT string look present, which refuses an absence claim -- fine. Asking
    the same table whether a value is PRESENT inverts that: a collision would admit a citation to
    a string Apple does not ship. So a value citation resolves against full digests of the values
    actually cited, the same way a key citation does.
    """
    return os.path.join(INDEX_DIR, f"{source}.values.tsv")


def load_value_index(source: str) -> set:
    path = value_index_path(source)
    if not os.path.exists(path):
        return set()
    out = set()
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                raise CanonError(f"{path}:{number}: expected 2 tab-separated fields, "
                                 f"got {len(parts)}")
            out.add((parts[0], parts[1]))
    return out


def write_value_index(source: str, rows) -> int:
    os.makedirs(INDEX_DIR, exist_ok=True)
    unique = sorted(set(rows))
    with open(value_index_path(source), "w", encoding="utf-8") as handle:
        handle.write("# locale\tsha256[:12] of the normalized value\n")
        handle.write("# Generated by Scripts/logic_canon.py build. A VALUE citation carries no key:\n"
                     "# the claim is that Apple ships this string in this corpus and this locale,\n"
                     "# which is what a LabelSet matches on. Do not hand-edit.\n")
        for locale, digest in unique:
            handle.write(f"{locale}\t{digest}\n")
    return len(unique)


def folded_path(source: str, locale: str) -> str:
    """Beside the absence set, over `fold_for_near_miss`. Same format, different question."""
    return os.path.join(ABSENCE_DIR, f"{source}.{locale}.folded.u32")


def casefold_path(source: str, locale: str) -> str:
    """Beside the absence set, over `fold_case`. Same format; the question a LabelSet asks."""
    return os.path.join(ABSENCE_DIR, f"{source}.{locale}.casefold.u32")


def _absence_file(source: str, locale: str, folded: bool, casefold: bool) -> str:
    if folded and casefold:
        raise CanonError("an absence set is folded for near misses or case-folded, not both")
    if casefold:
        return casefold_path(source, locale)
    return folded_path(source, locale) if folded else absence_path(source, locale)


def load_index(source: str) -> dict[tuple[str, str, str, str], str]:
    """The committed key->digest table for one source.

    The index holds ONLY keys something in this repository cites. That is a deliberate bound: the
    full QuickHelp index is 390,820 rows and would make every citation change a multi-megabyte
    diff, which is how a checked-in artefact stops being read. Growth is driven by
    `build`, which scans the tree for references and resolves exactly those (`--no-citations`
    skips that pass).

    An earlier version of this docstring said 295,050 -- 9835 x 10 x 3, arithmetic over three
    fields, taken without running the extractor and omitting the `composed` field the index
    actually stores. `logic_canon.py census` prints the real figure.
    """
    path = index_path(source)
    if not os.path.exists(path):
        return {}
    table: dict[tuple[str, str, str, str], str] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 5:
                raise CanonError(f"{path}:{number}: expected 5 tab-separated fields, got {len(parts)}")
            unit, locale, key, field, short = parts
            table[(_pct_decode(unit), locale, _pct_decode(key), field)] = short
    return table


def write_index(source: str, rows: dict[tuple[str, str, str, str], str]) -> None:
    os.makedirs(INDEX_DIR, exist_ok=True)
    with open(index_path(source), "w", encoding="utf-8") as handle:
        handle.write("# unit\tlocale\tkey\tfield\tsha256[:12] of the normalized value\n")
        handle.write("# Generated by Scripts/logic_canon.py build. Do not hand-edit: every row is\n")
        handle.write("# a digest of bytes inside Logic, and a typed one is a claim about Apple's\n")
        handle.write("# data that nothing measured.\n")
        for (unit, locale, key, field) in sorted(rows):
            handle.write(f"{_pct_encode(unit)}\t{locale}\t{_pct_encode(key)}\t{field}\t"
                         f"{rows[(unit, locale, key, field)]}\n")


def write_absence(source: str, locale: str, values, *, folded: bool = False,
                  casefold: bool = False) -> int:
    """Write the sorted 32-bit digest prefixes of every value seen. Returns how many were kept.

    `folded` writes the same structure over `fold_for_near_miss` instead, which is how `absent`
    can say "and nothing in the corpus differs from this only by decoration" without Logic.
    `casefold` writes it over `fold_case`, which is how `locale_labels.py` asks whether a member
    is shipped in the form the product matches it (#981).
    """
    os.makedirs(ABSENCE_DIR, exist_ok=True)
    path = _absence_file(source, locale, folded, casefold)
    key = fold_for_near_miss if folded else fold_case if casefold else (lambda v: v)
    unique = sorted({_u32(key(value)) for value in values if value})
    with open(path, "wb") as handle:
        handle.write(b"LCA1")
        handle.write(struct.pack(">I", len(unique)))
        for item in unique:
            handle.write(struct.pack(">I", item))
    return len(unique)


#: Absence sets are read once per process. `verify_buckets_offline` asks 410 literals about 23
#: corpora, which re-read the same twenty files 9,430 times and took the guard past two minutes.
#: Keyed by path AND by the file's size and modification time, so a file rewritten underneath the
#: process is re-read. Keyed on the path alone first, and the very test that exists to catch a
#: shrunken absence set went green: it writes the file directly rather than through
#: `write_absence`, the cache handed back the old table, and the check reported nothing wrong.
#: A cache that can hide the change a check exists to find is worse than no cache.
_ABSENCE_CACHE: dict = {}


def load_absence(source: str, locale: str, *, folded: bool = False,
                 casefold: bool = False) -> list[int]:
    path = _absence_file(source, locale, folded, casefold)
    try:
        stamp = os.stat(path)
        key = (path, stamp.st_size, stamp.st_mtime_ns)
    except OSError:
        key = None
    if key is not None:
        cached = _ABSENCE_CACHE.get(key)
        if cached is not None:
            return cached
    if not os.path.exists(path):
        raise CanonError(
            f"no absence set for {source}/{locale}: an absence claim over a corpus nobody built "
            f"is not a proof. Run Scripts/logic_canon.py build on a machine with Logic.")
    with open(path, "rb") as handle:
        blob = handle.read()
    if blob[:4] != b"LCA1":
        raise CanonError(f"{path}: not an absence set")
    count = struct.unpack_from(">I", blob, 4)[0]
    if len(blob) != 8 + 4 * count:
        raise CanonError(f"{path}: declares {count} entries but holds {len(blob) - 8} bytes")
    table = list(struct.unpack_from(f">{count}I", blob, 8))
    if key is not None:
        _ABSENCE_CACHE[key] = table
    return table


def differs_only_by_decoration(source: str, locale: str, text: str) -> bool:
    """The corpus holds something that folds to this, though not this.

    True means `text` is absent AS BYTES and a shipped label folds to it -- a colon, an ellipsis,
    a capital, a space. The claim "uncitable" is then almost certainly wrong, and the author
    typed the label slightly differently from the way Logic ships it.

    Measured on the control-surface branch: `Input Port:`, `Output Port:` and `Model:` were each
    proved absent from all 24 corpora, and Logic ships `Input Port`, `Output Port` and `Model`.
    None had been read off a screen; the observation record names `Input Port` zero times.
    """
    if not is_absent(source, locale, text):
        return False
    table = load_absence(source, locale, folded=True)
    needle = _u32(fold_for_near_miss(text))
    position = bisect.bisect_left(table, needle)
    return position < len(table) and table[position] == needle


def is_absent(source: str, locale: str, text: str) -> bool:
    """Whether `text` is absent from the pinned corpus for this source and locale.

    False means "present, or colliding with something present". True means absent, and a 32-bit
    set cannot produce a false True: every value that IS in the corpus put its own prefix in the
    set. So a True here is a real absence and a False sends the claim back for a look on a machine
    with Logic -- the asymmetry the module docstring promises.
    """
    table = load_absence(source, locale)
    needle = _u32(text)
    position = bisect.bisect_left(table, needle)
    return not (position < len(table) and table[position] == needle)


def is_absent_ignoring_case(source: str, locale: str, text: str) -> bool:
    """`is_absent`, asked the way a LabelSet matches: nothing in the corpus equals `text` up to case.

    The byte-exact question understated coverage. `mixerNamedElement`'s canonical is `mixer`, a
    German Logic ships the row capitalised, and every matcher the product has ignores case -- so
    the label matched in de-DE while this corpus said Apple ships nothing for it (#981). Only case
    is forgiven: a string that differs from every shipped value in any other way is still absent.
    The collision asymmetry is the same as `is_absent`'s, over the case-folded set.
    """
    table = load_absence(source, locale, casefold=True)
    needle = _u32(fold_case(text))
    position = bisect.bisect_left(table, needle)
    return not (position < len(table) and table[position] == needle)


# ---------------------------------------------------------------------------
# the manifest -- which bytes the index was taken over
# ---------------------------------------------------------------------------

def _file_digest(path: str) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def corpus_files(app: str, source: str) -> list[str]:
    """Every file in the bundle the named source reads. Sorted, bundle-relative."""
    out: list[str] = []
    if source == "quickhelp":
        resources = os.path.join(app, "Contents", "Resources")
        for entry in sorted(os.listdir(resources)):
            if entry.endswith(".lproj"):
                for base in ("QuickHelp.plist", "QuickHelpDefault.plist"):
                    path = os.path.join(resources, entry, base)
                    if os.path.exists(path):
                        out.append(_rel(app, path))
    elif source == "strings":
        for root, _dirs, files in os.walk(app):
            for name in files:
                if name.endswith(".strings"):
                    out.append(_rel(app, os.path.join(root, name)))
    elif source == "madsp":
        resources = os.path.join(
            app, "Contents", "Frameworks", "MADSP.framework", "Versions", "A", "Resources")
        if os.path.isdir(resources):
            for name in sorted(os.listdir(resources)):
                if name.endswith(".plist") and name not in {"Info.plist", "version.plist"}:
                    out.append(_rel(app, os.path.join(resources, name)))
    elif source == "nib":
        for root, _dirs, files in os.walk(app):
            for name in files:
                if name.endswith(".nib"):
                    out.append(_rel(app, os.path.join(root, name)))
    elif source == "nibstrings":
        for root, _dirs, files in os.walk(app):
            if os.path.basename(root) != "Base.lproj":
                continue
            for name in files:
                if name.endswith(".nib"):
                    out.append(_rel(app, os.path.join(root, name)))
    else:
        # A source with no branch here returned an EMPTY list, so its manifest entry recorded
        # `files: 0` and a corpus digest taken over nothing -- and `status` would then call the
        # corpus current against any Logic at all. Silence is the wrong answer to "which bytes is
        # this source made of".
        raise CanonError(
            f"corpus_files has no branch for source {source!r}. Add one: a source whose file list "
            f"is empty is pinned against no bytes, and every drift check over it is vacuous.")
    return sorted(out)


def corpus_digest(app: str, paths: list[str]) -> str:
    """One digest over every byte the corpus is made of, taken path by path.

    Not a digest of the concatenation: a digest of the sorted `path\\tfiledigest` stream. That way
    a file MOVING changes the result, which a concatenation would hide, and a file being added or
    dropped changes it too. An index whose manifest digest no longer matches the installed Logic
    was taken over different bytes and nothing built on it may be trusted.
    """
    hasher = hashlib.sha256()
    for rel in paths:
        hasher.update(f"{rel}\t{_file_digest(os.path.join(app, rel))}\n".encode("utf-8"))
    return hasher.hexdigest()


def app_build(app: str) -> dict:
    info = load_plist(os.path.join(app, "Contents", "Info.plist"))
    return {"app": info.get("CFBundleName", "Logic Pro"),
            "version": str(info.get("CFBundleShortVersionString", "")),
            "build": str(info.get("CFBundleVersion", ""))}


def load_manifest() -> dict:
    if not os.path.exists(MANIFEST_PATH):
        raise CanonError(
            "docs/canon/MANIFEST.json is missing. Nothing offline can be checked without it: it "
            "is the record of which Logic bytes the committed index was taken over.")
    with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


# ---------------------------------------------------------------------------
# resolving a citation
# ---------------------------------------------------------------------------

def resolve_offline(ref: CanonRef) -> str:
    """The committed digest for a reference. Raises when it is not in the index.

    A VALUE citation has no key, so there is no row to return a digest FROM: the claim is that
    Apple ships some string here, and which string is carried by the citation's own `value`. It is
    checkable only as a pair, which `check_citation` does. Callers that scan prose for references
    and resolve each one -- proving the reference is pinned at all -- ask this instead, so it
    answers for the source rather than for a row.
    """
    if ref.is_value_citation:
        if not load_value_index(ref.source):
            raise CanonResolveError(
                f"{ref}: docs/canon/index/{ref.source}.values.tsv is missing or empty, so no value "
                f"citation for this source is pinned. Run Scripts/logic_canon.py build on a "
                f"machine with Logic.")
        return ""
    table = load_index(ref.source)
    row = table.get(ref.index_row())
    if row is None:
        raise CanonResolveError(
            f"{ref} is not in docs/canon/index/{ref.source}.tsv.\n"
            f"  A citation must be resolved against Logic once, on a machine that has it, before "
            f"anything offline can check it. Run:\n"
            f"    Scripts/logic_canon.py build")
    return row


def check_citation(ref_text: str, quoted_value: str) -> None:
    """Refuse unless the quoted value is the value Logic ships under that reference.

    This is the whole point of the citation format. A reference alone proves nothing -- anyone can
    type a key. A reference PLUS the value it resolves to is checkable, and the check is that the
    digest of the quoted value equals the digest the index recorded from Apple's own bytes.
    """
    ref = CanonRef.parse(ref_text)
    if ref.is_value_citation:
        # No key, so nothing to look up by row: the claim is that Apple ships this string in this
        # corpus and locale, and `build` confirmed it against Logic and pinned its full digest.
        pinned = load_value_index(ref.source)
        if not pinned:
            raise CanonResolveError(
                f"{ref}: docs/canon/index/{ref.source}.values.tsv is missing or empty, so no value "
                f"citation for this source can be checked. Run Scripts/logic_canon.py build on a "
                f"machine with Logic.")
        if (ref.locale, short_digest(quoted_value)) not in pinned:
            raise CanonResolveError(
                f"{ref}\n"
                f"  {quoted_value!r} is not pinned for {ref.source}/{ref.locale}.\n"
                f"  Either Logic does not ship it there, or the build has not seen this citation "
                f"yet -- run Scripts/logic_canon.py build.")
        return
    committed = resolve_offline(ref)
    quoted = short_digest(quoted_value)
    if quoted != committed:
        raise CanonResolveError(
            f"{ref}\n"
            f"  quoted value hashes to {quoted}, Logic's value hashes to {committed}.\n"
            f"  The quote is wrong, or it was taken from a different Logic build than the one\n"
            f"  docs/canon/MANIFEST.json pins. Either way the citation does not hold.")


# ---------------------------------------------------------------------------
# scanning the repository for citations
# ---------------------------------------------------------------------------

#: Where a citation may appear. Everything this repository produces is in here on purpose: the
#: rule is that no artefact -- prose or code -- states a fact about Logic without citing Logic.
CITATION_ROOTS = ("docs", "Sources", "Tests", "Scripts", ".github")

_SKIP_DIRS = {".git", ".build", "node_modules", "__pycache__", "index", "absence"}

#: Files whose references are deliberately broken. A guard's own tests inject malformed and
#: unresolvable references on purpose -- that is what proves the guard refuses them -- so scanning
#: them would make the guard fail on its own evidence. The cost is stated rather than hidden: a
#: genuine citation written inside a test is not pinned and not checked.
#: Repository-RELATIVE paths, not basenames. Matched by basename first, which exempted any file
#: anywhere in the tree sharing one of these names -- `docs/notes/logic_canon.py` carrying an
#: unresolvable reference passed. Citation scanning must not be opt-out by filename.
_SKIP_FILES = {
    os.path.join("Scripts", "test_logic_canon.py"),
    os.path.join("Scripts", "test_canon_citations_guard.py"),
    os.path.join("Scripts", "logic_canon.py"),
    os.path.join("Scripts", "check-canon-citations.py"),
}
#: Deliberately broad. A citation in a file type nobody listed is a citation nobody checks, and
#: the first list stopped at nine suffixes -- so a reference in a `.rb` Formula, a `.toml`, a
#: `.strings` fixture or an extensionless script was invisible. Reading a file that turns out to be
#: binary costs a caught UnicodeDecodeError, which is cheaper than the hole.
_TEXT_SUFFIXES = {".json", ".md", ".swift", ".py", ".sh", ".yml", ".yaml", ".tsv", ".txt",
                  ".rb", ".toml", ".cfg", ".ini", ".xml", ".plist", ".strings", ".jsonc",
                  ".mjs", ".js", ".ts", ".c", ".h", ".m", ".mm", ".bash", ".zsh", ".env", ""}


def scan_value_citations(repo: str = REPO) -> set:
    """Every (source, locale, value) a record cites WITHOUT a key.

    A value citation is a (ref, value) pair, and only the record knows the value, so this reads
    the `canon` blocks rather than scanning prose for references. That is the whole difference
    from a key citation: the key is in the reference and the value is the thing being claimed.
    """
    out = set()
    root = os.path.join(repo, "docs", "observations")
    if not os.path.isdir(root):
        return out
    for name in sorted(os.listdir(root)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(root, name), "r", encoding="utf-8") as handle:
                record = json.load(handle)
        except (OSError, ValueError):
            continue
        if not isinstance(record, dict):
            continue
        for citation in record.get("canon") or []:
            ref_text, value = citation.get("ref"), citation.get("value")
            if not ref_text or value is None:
                continue
            try:
                ref = CanonRef.parse(ref_text)
            except CanonRefError:
                continue
            if ref.is_value_citation:
                out.add((ref.source, ref.locale, value))
    return out


def scan_repo_citations(repo: str = REPO) -> dict[str, list[str]]:
    """Every canonical reference in the tree, mapped to the files that state it."""
    found: dict[str, list[str]] = {}
    generated = os.path.join(repo, "docs", "canon")
    for top in CITATION_ROOTS:
        base = os.path.join(repo, top)
        if not os.path.isdir(base):
            continue
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in _SKIP_DIRS]
            # docs/canon is this module's own output. Scanning it feeds unresolved references
            # recorded in MANIFEST.json back in as citations to resolve, which never converges.
            if os.path.commonpath([os.path.abspath(root), generated]) == generated:
                continue
            for name in sorted(files):
                if os.path.relpath(os.path.join(root, name), repo) in _SKIP_FILES:
                    continue
                if os.path.splitext(name)[1] not in _TEXT_SUFFIXES:
                    continue
                path = os.path.join(root, name)
                try:
                    with open(path, "r", encoding="utf-8") as handle:
                        body = handle.read()
                except (UnicodeDecodeError, OSError):
                    continue
                for ref in find_refs(body):
                    found.setdefault(ref, []).append(os.path.relpath(path, repo))
    return found


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def corpus_shape(app: str) -> dict:
    """The structural facts a surrogate corpus needs in order to stand for the real one.

    Published because the surrogate test claimed to read the shape and did not -- its parameters
    were typed into the fixture, which is the same defect as a number typed into prose. These are
    all near-linear: the suffix-pair count buckets by the last twelve characters first, so it does
    not pay the quadratic price of comparing every composition with every other.
    """
    out = {}
    for locale in EXPECTED_LOCALES:
        path = os.path.join(app, "Contents", "Resources", f"{locale}.lproj", "QuickHelp.plist")
        if not os.path.exists(path):
            continue
        index = QuickHelpIndex.from_app(app, locale, min_anchor=1)
        lengths = sorted(len(c) for c in index.by_composed)
        sizes = [len(keys) for keys in index.by_composed.values()]
        buckets: dict = {}
        for composed in index.by_composed:
            if len(composed) >= 12:
                buckets.setdefault(composed[-12:], []).append(composed)
        pairs = 0
        for group in buckets.values():
            if len(group) < 2:
                continue
            for short in group:
                for long in group:
                    if long is not short and len(long) > len(short) and long.endswith(short):
                        pairs += 1
        out[locale] = {
            "compositions": len(index.by_composed),
            "shortest": lengths[0],
            "median_length": lengths[len(lengths) // 2],
            "shared_by_more_than_one_key": sum(1 for n in sizes if n > 1),
            "most_keys_on_one_composition": max(sizes),
            "suffix_pairs": pairs,
        }
    return out


def round_trip_report(app: str) -> dict:
    """Compose every QuickHelp entry the way Logic does, parse it back, and require the same keys.

    This is the assertion the parser rests on, and it was a TEST -- one that skips without Logic,
    which is every CI runner, so the strongest check in the suite ran nowhere that mattered.

    The fix is not to weaken it. It is to run it where the corpus is: `build` is the only thing that
    ever touches Apple's bytes, so `build` is where a claim about them belongs. A corpus that fails
    the round trip does not get an index written for it, and everything offline is checked against
    an index that could only have come from a corpus that passed.

    Both tiers, and a runtime prefix on each, because the prefix is what a live reading carries.
    """
    out = {}
    prefixes = ["\ud074", "\uc7ac\uc0dd   \u2305",
                "\uc774 \ucee8\ud2b8\ub864\uc744 \uc0ac\uc6a9\ud560 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4."]
    for locale in EXPECTED_LOCALES:
        path = os.path.join(app, "Contents", "Resources", f"{locale}.lproj", "QuickHelp.plist")
        if not os.path.exists(path):
            continue
        index = QuickHelpIndex.from_app(app, locale)
        checked = bare = prefixed = 0
        for position, (composed, keys) in enumerate(sorted(index.by_composed.items())):
            if len(composed) < index.min_anchor:
                continue
            checked += 1
            match = index.parse_axhelp(composed)
            if match is not None and set(match.keys) == set(keys):
                bare += 1
            prefix = prefixes[position % len(prefixes)]
            match = index.parse_axhelp(f"{prefix}, {composed}")
            if match is not None and set(match.keys) == set(keys) and match.prefix == prefix:
                prefixed += 1
        out[locale] = {"compositions": checked, "whole": bare, "with_a_runtime_prefix": prefixed}
    return out


def derive_translated_english(app: str, extractors: dict | None = None) -> list[int]:
    """Which English values Apple TRANSLATES, as 32-bit digests, so a guard can ask offline.

    CI has no Logic, and "does Apple translate this label" is what decides whether matching it by
    literal is a localisation bug -- the first version of the AX-comparison guard read the bundle
    for this and therefore could not run in the one place the answer is needed.

    Over EVERY source, never a subset. This is one global artefact with no per-source partition, so
    deriving it from a partial rebuild would rewrite the whole answer from a fraction of the corpus
    -- the same shape as the `manifest["sources"]` bug at the top of `build`, and just as quiet,
    because the file that results is well-formed and simply smaller.

    And grouped under TRANSLATION_NAMESPACE rather than under the source name. English for a
    base-internationalised table lives in `nibstrings` while its nine translations live in
    `strings`; keyed by source they never meet, so all 6,270 of those English labels would be
    recorded as strings Apple does not translate -- the answer that EXEMPTS a literal comparison
    from needing a LabelSet. Wrong in the permissive direction, in the guard this file serves.
    `extract_nibstrings` names its unit as the overlay's own address precisely so this join lands.
    """
    rows: dict = {}
    for source in sorted(extractors if extractors is not None else EXTRACTORS):
        namespace = TRANSLATION_NAMESPACE.get(source, source)
        extractor = (extractors if extractors is not None else EXTRACTORS)[source]
        for unit, locale, key, field, value in extractor(app):
            rows.setdefault((namespace, unit, key, field), {})[locale] = value
    translated = set()
    untranslated = set()
    for per in rows.values():
        english = per.get("en")
        if english is None:
            continue
        folded = normalize(english)
        others = {normalize(value) for locale, value in per.items() if locale != "en"}
        (translated if others - {folded} else untranslated).add(folded)
    # A SET of digests, not of strings. Two English values can truncate to the same 32 bits, and
    # emitting both wrote a duplicate entry into the file -- measured: one duplicate across 68,417.
    # The reader treats the file as a set either way, so it cost nothing but a wrong count and an
    # artefact that would not reproduce from a differently-ordered walk.
    return sorted({_u32(text) for text in translated})


def build(app: str, *, sources: list[str], refresh_citations: bool, repo: str = REPO) -> dict:
    """Extract the corpus, write the absence sets, pin the manifest, resolve every citation.

    Needs Logic. Everything else in this module needs only what this writes.
    """
    # Start from what is already pinned. `build --source strings` used to write a manifest holding
    # ONLY that source, and `required_corpora` reads the manifest -- so a documented flag silently
    # shrank every absence proof to the corpora that happened to be rebuilt, with no warning and
    # with `verify_artifacts` still green because the orphaned absence files were re-digested.
    # Found by review 2026-09-15.
    previous = load_manifest() if os.path.exists(MANIFEST_PATH) else {}
    manifest = {"schema": 1, "extractor_version": EXTRACTOR_VERSION,
                "logic": app_build(app),
                "sources": dict(previous.get("sources") or {})}
    if previous.get("logic") and previous["logic"] != manifest["logic"]:
        # A partial rebuild on a DIFFERENT Logic would leave some sources describing one build and
        # some another, and nothing downstream could tell. Refuse rather than mix.
        if set(sources) != set(EXTRACTORS):
            raise CanonError(
                f"this Logic is {manifest['logic']} and the pinned manifest is {previous['logic']}. "
                f"A partial rebuild across builds would leave sources describing different "
                f"applications. Rebuild every source.")
        manifest["sources"] = {}
    cited = scan_repo_citations(repo) if refresh_citations else {}
    by_source: dict[str, dict[tuple[str, str, str, str], str]] = {}
    folded_by_source: dict[str, dict[tuple[str, str, str, str], str]] = {}
    values_by_locale_by_source: dict[str, dict[str, set]] = {}

    for source in sources:
        extractor = EXTRACTORS[source]
        values_by_locale: dict[str, set[str]] = {}
        rows: dict[tuple[str, str, str, str], str] = {}
        folded_rows: dict[tuple[str, str, str, str], str] = {}
        entries = 0
        for unit, locale, key, field, value in extractor(app):
            entries += 1
            folded = normalize(value)
            values_by_locale.setdefault(locale, set()).add(folded)
            rows[(unit, locale, key, field)] = short_digest(value)
            folded_rows[(unit, locale, key, field)] = short_digest(normalize(value).casefold())
        if source == "quickhelp" and EXPECTED_LOCALES:
            # BOTH directions. The first version compared only one way, so a Logic that ADDED a
            # locale left the corpus quietly narrower than the application -- and every absence
            # claim would then be taken over nine tenths of what Apple ships while reading as
            # though it covered all of it.
            extra = sorted(set(values_by_locale) - set(EXPECTED_LOCALES))
            if extra:
                raise CanonError(
                    f"QuickHelp ships locales this build does not know about: {extra}. Add them to "
                    f"EXPECTED_LOCALES -- an absence claim over a corpus narrower than the "
                    f"application is not a proof about the application. Nothing has been written.")
            missing = sorted(set(EXPECTED_LOCALES) - set(values_by_locale))
            if missing:
                # BEFORE any write. The check used to run after the loop below, which had already
                # overwritten the absence files -- so the promise to "stop the build rather than
                # shrink" protected the manifest and not the artefacts.
                raise CanonError(
                    f"QuickHelp is missing locales {missing}. A corpus that lost a locale makes "
                    f"every absence claim over it false, so this stops the build rather than "
                    f"shrinking. Nothing has been written.")
        paths = corpus_files(app, source)
        absence_counts, folded_counts, casefold_counts = {}, {}, {}
        for locale, values in sorted(values_by_locale.items()):
            absence_counts[locale] = write_absence(source, locale, values)
            folded_counts[locale] = write_absence(source, locale, values, folded=True)
            casefold_counts[locale] = write_absence(source, locale, values, casefold=True)
        manifest["sources"][source] = {
            "files": len(paths),
            "entries": entries,
            "corpus_digest": corpus_digest(app, paths),
            "locales": sorted(values_by_locale),
            "absence_entries": absence_counts,
            "folded_entries": folded_counts,
            "casefold_entries": casefold_counts,
            "absence_false_positive": {
                locale: round(absence_false_positive(count), 12)
                for locale, count in absence_counts.items()},
        }
        by_source[source] = rows
        folded_by_source[source] = folded_rows
        values_by_locale_by_source[source] = values_by_locale

    if refresh_citations:
        # Rows a citation in ANOTHER source pins here, because one row can span two sources.
        # Collected across the whole loop and merged at the end, so a citation naming `strings`
        # can pin the English that only `nibstrings` has regardless of which is visited first.
        cross_namespace: dict[str, dict[tuple[str, str, str, str], str]] = {}
        for source in sources:
            wanted: dict[tuple[str, str, str, str], str] = {}
            unresolved = []
            for ref_text in cited:
                try:
                    ref = CanonRef.parse(ref_text)
                except CanonRefError:
                    unresolved.append(ref_text)
                    continue
                if ref.source != source:
                    continue
                if ref.is_value_citation:
                    # Confirmed below, against the locale's VALUE set, because a value citation
                    # names no key and so addresses no row. Sending it down the row path reported
                    # `logic-canon://strings/en#value` as an unresolved citation in the manifest
                    # for every build that has one -- a standing false alarm about a reference the
                    # same run had just confirmed, next to the real unresolved ones.
                    continue
                row = by_source[source].get(ref.index_row())
                if row is None:
                    unresolved.append(ref_text)
                    continue
                wanted[ref.index_row()] = row
                # And the SAME row in every other locale the source carries. A citation names one
                # locale, but the thing worth checking offline is almost never one locale: it is
                # that this control says the same thing in every language Logic ships. Without the
                # siblings, a derivation over ten locales can only be verified on a machine that
                # has Logic -- which is the one place the answer is not needed. Ten digests per
                # citation is the whole cost.
                unit, _locale, key, field = ref.index_row()
                for sibling_locale in sorted(values_by_locale_by_source.get(source) or {}):
                    sibling = (unit, sibling_locale, key, field)
                    digest = by_source[source].get(sibling)
                    if digest is not None:
                        wanted[sibling] = digest
                        folded = folded_by_source.get(source, {}).get(sibling)
                        if folded is not None:
                            wanted[(unit, sibling_locale, key, field + CASE_INSENSITIVE)] = folded
                # And across the namespace, because a single row can span two SOURCES. Apple
                # compiles the English of 162 tables into `Base.lproj` nibs and ships the nine
                # translations as `.strings`, so `GotoPosition.strings 5.title` is `nibstrings` in
                # English and `strings` everywhere else. A reference names one source; the row it
                # names does not stop there, and pinning only the cited source leaves the English
                # of every base-internationalised table unpinned -- which reads, offline, as a
                # reference nobody ever resolved.
                namespace = TRANSLATION_NAMESPACE.get(source, source)
                for other in sources:
                    if other == source:
                        continue
                    if TRANSLATION_NAMESPACE.get(other, other) != namespace:
                        continue
                    for sibling_locale in sorted(values_by_locale_by_source.get(other) or {}):
                        sibling = (unit, sibling_locale, key, field)
                        digest = by_source[other].get(sibling)
                        if digest is not None:
                            cross_namespace.setdefault(other, {})[sibling] = digest
                            folded = folded_by_source.get(other, {}).get(sibling)
                            if folded is not None:
                                cross_namespace[other][
                                    (unit, sibling_locale, key, field + CASE_INSENSITIVE)] = folded
            # Keep rows already committed even when nothing cites them this run, so that removing
            # one citation does not silently un-pin a digest another branch is still resting on --
            # but the FRESH digest wins where both have the row. Written the other way round first,
            # and `dict.update` overwrites: a rebuild after a Logic update kept every stale digest,
            # so a citation whose string Apple had changed went on resolving. That is the exact
            # failure `docs/canon/README.md` says a rebuild exists to surface, and the code did the
            # opposite. Found by review 2026-09-15 with a synthetic two-build corpus.
            # VALUE citations: confirmed against the corpus just extracted, then pinned by full
            # digest. `by_source` is keyed by row; the values themselves are what a value citation
            # claims, so they are checked against the locale's value set.
            value_rows = set(load_value_index(source))
            unconfirmed = []
            for cited_source, locale, value in scan_value_citations(repo):
                if cited_source != source:
                    continue
                if normalize(value) in (values_by_locale_by_source.get(source) or {}).get(locale, ()):
                    value_rows.add((locale, short_digest(value)))
                else:
                    unconfirmed.append(f"{locale}: {value!r}")
            write_value_index(source, value_rows)
            manifest["sources"][source]["cited_values"] = len(value_rows)
            if unconfirmed:
                manifest["sources"][source]["unconfirmed_values"] = sorted(unconfirmed)

            merged = load_index(source)
            merged.update(wanted)
            write_index(source, merged)
            wanted = merged
            manifest["sources"][source]["cited_rows"] = len(wanted)
            if unresolved:
                manifest["sources"][source]["unresolved_citations"] = sorted(set(unresolved))

        # Merged AFTER the loop, so a source that was visited before the citation naming its row
        # still receives the rows that citation pins. Collected during the loop and written once.
        for other, rows_to_pin in sorted(cross_namespace.items()):
            if other not in sources:
                continue
            merged = load_index(other)
            before = len(merged)
            merged.update(rows_to_pin)
            if len(merged) != before or any(merged[row] != rows_to_pin[row] for row in rows_to_pin):
                write_index(other, merged)
            manifest["sources"][other]["cited_rows"] = len(merged)

    # Which English values Apple TRANSLATES, as digests, so a guard can ask offline. CI has no
    # Logic, and "does Apple translate this label" is what decides whether matching it by literal
    # is a localisation bug -- the first version of the AX-comparison guard read the bundle for
    # this and therefore could not run in the one place the answer is needed.
    translated = derive_translated_english(app)
    os.makedirs(ABSENCE_DIR, exist_ok=True)
    with open(translated_path(), "wb") as handle:
        handle.write(b"LCA1")
        handle.write(struct.pack(">I", len(translated)))
        for item in translated:
            handle.write(struct.pack(">I", item))
    manifest["translated_en_values"] = len(translated)

    if "quickhelp" in manifest["sources"]:
        manifest["sources"]["quickhelp"]["identical_files"] = verify_quickhelp_aliases(app)

    # Every committed artefact is digested INTO the manifest. Without this the offline check has
    # no integrity at all: `index/<source>.tsv` is the table a quoted value is compared against, so
    # a hand-typed row makes any quote pass, and `absence/*.u32` is what an absence claim is proved
    # against, so a truncated file makes any string look absent. Both are generated files that look
    # exactly like edited ones.
    if "quickhelp" in manifest["sources"]:
        report = round_trip_report(app)
        manifest["sources"]["quickhelp"]["round_trip"] = report
        manifest["sources"]["quickhelp"]["shape"] = corpus_shape(app)
        broken = {locale: row for locale, row in report.items()
                  if row["whole"] != row["compositions"]
                  or row["with_a_runtime_prefix"] != row["compositions"]}
        if broken:
            raise CanonError(
                f"the parser does not round trip this corpus: {broken}. An index written over a "
                f"corpus the parser cannot reverse is an index whose citations mean nothing, so "
                f"nothing is written. This check lives here rather than in a test because a test "
                f"that needs Logic runs nowhere that gates anything.")

    manifest["artifacts"] = artifact_digests()
    os.makedirs(CANON_DIR, exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    return manifest


def verify_quickhelp_aliases(app: str) -> dict:
    """Check the alias table against the bytes, and record what was actually found.

    `QUICKHELP_LOCALE_ALIASES` was a dead constant: defined, never read, and therefore a comment
    with the shape of a rule. It asserts that `it`, `pt` and `zh_TW` ship English -- which is load
    bearing, because it is why a claim of agreement "across ten locales" counts three agreements
    that are true by construction. If Apple translates one of them in a later build, nothing would
    have noticed and the claim would quietly become three claims too strong.

    So `build` groups the files by digest and refuses a grouping that disagrees with the table. The
    grouping also goes into the manifest, where a change is visible in the diff rather than only in
    a number nobody recomputes.
    """
    resources = os.path.join(app, "Contents", "Resources")
    by_digest: dict[str, list[str]] = {}
    for entry in sorted(os.listdir(resources)):
        if not entry.endswith(".lproj"):
            continue
        path = os.path.join(resources, entry, "QuickHelp.plist")
        if os.path.exists(path):
            by_digest.setdefault(_file_digest(path), []).append(entry[: -len(".lproj")])
    groups = {digest[:12]: sorted(locales) for digest, locales in by_digest.items()}

    same_as = {}
    for locales in by_digest.values():
        if "en" in locales:
            for locale in locales:
                if locale != "en":
                    same_as[locale] = "en"
    if same_as != QUICKHELP_LOCALE_ALIASES:
        raise CanonError(
            f"QUICKHELP_LOCALE_ALIASES says {QUICKHELP_LOCALE_ALIASES} and this Logic ships "
            f"{same_as}. The table is why a claim across ten locale NAMES is not a claim across "
            f"ten independent files, so it may not drift silently.")
    return groups


def artifact_digests() -> dict:
    """sha256 of every committed index and absence file, keyed by path relative to docs/canon."""
    out = {}
    for directory in (INDEX_DIR, ABSENCE_DIR):
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            path = os.path.join(directory, name)
            if os.path.isfile(path):
                out[os.path.relpath(path, CANON_DIR)] = _file_digest(path)
    return out


def verify_absence_counts(manifest: dict) -> list:
    """Every absence set holds the number of entries the manifest says it holds.

    `verify_artifacts` digests the files, which catches an edit -- but only against a manifest
    nobody also edited. This is the cheap second reading: the manifest states a COUNT per locale,
    and a shrunken absence set has fewer. Removing an entry is how a string Logic ships is proved
    absent, and the demonstration is one line: drop one value, rewrite the header, and
    `is_absent` flips from False to True for a string that is in the corpus.

    It is not a cryptographic control and nothing offline can be. It makes the forgery need three
    consistent edits -- the binary set, its digest, and a number a reviewer reads -- instead of two.
    """
    # The case-folded set is read in the other direction -- a value found there makes a label
    # `derived` -- so an entry ADDED to it is the forgery that matters, and a count catches that too.
    problems = []
    for source, block in (manifest.get("sources") or {}).items():
        for field, casefold, suffix in (("absence_entries", False, "u32"),
                                        ("casefold_entries", True, "casefold.u32")):
            for locale, declared in (block.get(field) or {}).items():
                try:
                    found = len(load_absence(source, locale, casefold=casefold))
                except CanonError as exc:
                    problems.append(f"absence/{source}.{locale}.{suffix}: {exc}")
                    continue
                if found != declared:
                    problems.append(
                        f"absence/{source}.{locale}.{suffix} holds {found} entries and "
                        f"MANIFEST.json declares {declared}. A set that lost entries proves strings "
                        f"absent that Logic ships; one that gained them credits strings it does not.")
    return problems


def verify_index_against_absence() -> list:
    """Every committed index row's value must also be in its corpus's absence set.

    A free invariant, and the only external check an offline run has. `short_digest` is the first
    12 hex of the value's SHA-256 and the absence set stores the first 8, so the index row already
    contains the key the absence set is searched by. A value Logic ships is in both by construction.

    What it buys: forging a citation now means editing THREE files consistently -- the index row,
    `MANIFEST.json`'s digest of it, and the sorted binary absence set -- instead of two. It does
    not make forgery impossible and nothing offline can; see the threat model in
    `docs/canon/README.md`. It raises the cost of the cheapest version from a text edit to a
    deliberate one, which is the difference between a shortcut somebody takes under deadline and an
    act nobody performs by accident.
    """
    problems = []
    # `*.tsv` also matches `<source>.values.tsv`, which is a VALUE index -- two columns, not five.
    # This walked it as a key index and died on the field count. A glob that predates a file type
    # does not know about it, and the one it does not know about is the one that breaks it.
    for path in sorted(glob.glob(os.path.join(INDEX_DIR, "*.tsv"))):
        if path.endswith(".values.tsv"):
            continue
        source = os.path.basename(path)[: -len(".tsv")]
        for (unit, locale, key, field), short in load_index(source).items():
            if field.endswith(CASE_INSENSITIVE):
                # A `#ci` row is the CASE-FOLDED digest of the row beside it, and the absence sets
                # preserve case on purpose -- so it cannot be found there and its absence proves
                # nothing. The exact row it accompanies IS checked here, and tampering with either
                # breaks the manifest digest over the whole index file. What this loop protects
                # against is a row that was never taken from the corpus at all, and a `#ci` row is
                # written only where its exact twin was.
                exact = (unit, locale, key, field[: -len(CASE_INSENSITIVE)])
                if exact not in load_index(source):
                    problems.append(
                        f"index/{source}.tsv pins a case-folded digest for {key!r} ({unit}, "
                        f"{locale}) with no exact row beside it. A folded digest alone is checked "
                        f"by nothing.")
                continue
            try:
                table = load_absence(source, locale)
            except CanonError as exc:
                problems.append(f"index/{source}.tsv row {key!r}: {exc}")
                continue
            needle = int(short[:8], 16)
            position = bisect.bisect_left(table, needle)
            if not (position < len(table) and table[position] == needle):
                problems.append(
                    f"index/{source}.tsv pins {key!r} ({unit}, {locale}, {field}) at digest "
                    f"{short}, and no value in absence/{source}.{locale}.u32 hashes to it. A row "
                    f"whose value is not in the corpus was not taken from the corpus.")
    return problems


def verify_artifacts(manifest: dict) -> list:
    """Refuse an index or absence set whose bytes are not the bytes `build` wrote.

    Returns complaints rather than raising, so a caller reports every drifted file at once. A
    missing `artifacts` block is itself a failure: an index built before this check existed carries
    no integrity claim, and treating "no claim" as "fine" makes the check satisfiable by deleting
    it.
    """
    declared = manifest.get("artifacts")
    if declared is None:
        return ["docs/canon/MANIFEST.json carries no `artifacts` block, so nothing pins the bytes "
                "of the index and absence files a citation is checked against. Rebuild."]
    found = artifact_digests()
    problems = []
    for path in sorted(set(declared) | set(found)):
        if path not in found:
            problems.append(f"docs/canon/{path} is declared in MANIFEST.json and is not on disk")
        elif path not in declared:
            problems.append(f"docs/canon/{path} is on disk and is not declared in MANIFEST.json -- "
                            f"a file nobody pinned is a file anybody can write")
        elif declared[path] != found[path]:
            problems.append(f"docs/canon/{path} does not match the digest MANIFEST.json pins. "
                            f"It was edited, or it was built by a different run.")
    return problems


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cmd_build(args) -> int:
    sources = args.source or sorted(EXTRACTORS)
    manifest = build(args.app, sources=sources, refresh_citations=not args.no_citations)
    print(f"Logic {manifest['logic']['version']} ({manifest['logic']['build']})")
    for source, block in sorted(manifest["sources"].items()):
        print(f"  {source:10s} files={block['files']:<6d} entries={block['entries']:<8d} "
              f"locales={len(block['locales']):<3d} cited={block.get('cited_rows', 0)}")
        worst = max(block["absence_false_positive"].values(), default=0.0)
        print(f"             absence sets: {len(block['absence_entries'])} "
              f"worst false-positive {worst:.3e}")
        if block.get("unresolved_citations"):
            print(f"             UNRESOLVED: {len(block['unresolved_citations'])}")
            for ref in block["unresolved_citations"][:5]:
                print(f"               {ref}")
    return 0


def _cmd_resolve(args) -> int:
    ref = CanonRef.parse(args.ref)
    if args.app and os.path.isdir(args.app):
        for unit, locale, key, field, value in EXTRACTORS[ref.source](args.app):
            if (unit, locale, key, field) == ref.index_row():
                print(value)
                return 0
        print(f"{ref}: not found in the installed Logic", file=sys.stderr)
        return 1
    print(resolve_offline(ref))
    return 0


def _cmd_locate(args) -> int:
    """Where a string lives in Logic, as references ready to paste into a record or a body."""
    if not os.path.isdir(args.app):
        print(f"{args.app} is not installed. `locate` reads Apple's bytes and cannot run without "
              f"them -- this is a build-time tool, like `build`.", file=sys.stderr)
        return 2
    hits = locate(args.app, args.text,
                  sources=[args.source] if args.source else None,
                  locales=[args.locale] if args.locale else None)
    if not hits:
        print(f"{args.text!r} is a whole value nowhere in the corpus. If a record needs it, that "
              f"is an absence claim: Scripts/logic_canon.py absent <source> <locale> <text>",
              file=sys.stderr)
        return 1
    if args.every:
        for source, unit, locale, key, field in hits:
            print(citation_for(source, unit, locale, key, field))
            print(f"  value:  {args.text}")
        return 0

    # Grouped by KEY, because that is the unit of the decision. A key is the same in every locale,
    # so `Smart Controls` printed forty-odd lines -- ten of them one QuickHelp key repeated once
    # per locale -- and a person cannot choose from that. Grouping turns the same answer into the
    # shape #892 measured: pick a key once and the locales follow.
    groups = group_by_key(hits)
    for source, unit, key, field, shown in groups:
        pick = "en" if "en" in shown else shown[0]
        print(citation_for(source, unit, pick, key, field))
        print(f"  value:  {args.text}")
        print(f"  locales: {len(shown)} -- {' '.join(shown)}")
    if len(groups) > 1:
        print(f"\n{len(groups)} candidate keys. The value does not choose between them and neither "
              f"does this: a key that resolves is not the same as the key that MEANS what the "
              f"change is about. `추가` is the value of `Add` and of a Drummer slider label.",
              file=sys.stderr)
    return 0


def _cmd_check(args) -> int:
    failures = 0
    for pair in args.pair:
        if "=" not in pair:
            print(f"expected <ref>=<value>, got {pair!r}", file=sys.stderr)
            failures += 1
            continue
        ref_text, value = pair.split("=", 1)
        try:
            check_citation(ref_text, value)
            print(f"ok  {ref_text}")
        except CanonError as exc:
            print(f"FAIL {exc}", file=sys.stderr)
            failures += 1
    return 1 if failures else 0


def _cmd_absent(args) -> int:
    absent = is_absent(args.source, args.locale, args.text)
    entries = len(load_absence(args.source, args.locale))
    rate = absence_false_positive(entries)
    if absent:
        if differs_only_by_decoration(args.source, args.locale, args.text):
            print(f"NOT PROVEN for {args.source}/{args.locale}: {args.text!r} is absent as bytes, "
                  f"and the corpus holds a label that differs from it only by decoration -- a "
                  f"colon, an ellipsis, a capital, a space.", file=sys.stderr)
            print(f"  Run: Scripts/logic_canon.py locate {args.text.rstrip(':… .')!r}",
                  file=sys.stderr)
            print(f"  Absent is still TRUE here -- these bytes are not in the corpus. Whether it "
                  f"is USEFUL depends on why the string exists: a LabelSet's `variants` are "
                  f"deliberate tolerance and absent is the right answer for them, while a "
                  f"`canonical` that is absent is usually a label typed slightly wrong. "
                  f"`check-policy-literals-against-canon.py` draws that line; this cannot.",
                  file=sys.stderr)
        print(f"ABSENT from {args.source}/{args.locale} "
              f"({entries} values pinned; not among them)")
        # The old wording here was "a false ABSENT is impossible", which is true of the DIGESTS --
        # a set cannot hide a value it holds, so no collision produces this answer -- and read as a
        # statement about Logic. It was measured misleading a reader: a corpus truncated to 50
        # entries printed exactly that sentence for `strings es Pista`, a string Logic ships.
        print(f"  No collision can cause this: a digest set cannot hide a value it holds. It is a "
              f"claim about these {entries} entries, not about Logic. A set built over less than "
              f"the corpus answers ABSENT for strings Logic ships.", file=sys.stderr)
        return 0
    print(f"PRESENT (or colliding) in {args.source}/{args.locale} "
          f"({entries} values pinned; collision chance {rate:.3e})", file=sys.stderr)
    return 1


def _cmd_axhelp(args) -> int:
    index = QuickHelpIndex.from_app(args.app, args.locale, min_anchor=args.min_anchor)
    values = ([args.value] if args.value else
              [line.rstrip("\n") for line in sys.stdin if line.strip()])
    for value in values:
        match = index.parse_axhelp(value)
        if match is None:
            print(json.dumps({"input": value, "match": None}, ensure_ascii=False))
        else:
            print(json.dumps({"input": value, **match.as_dict()}, ensure_ascii=False))
    return 0


def _cmd_thresholds(args) -> int:
    index = QuickHelpIndex.from_app(args.app, args.locale, min_anchor=1)
    lengths = sorted(len(c) for c in index.by_composed)
    print(f"{args.locale}: {len(index.by_composed)} distinct compositions")
    print(f"{'min':>5} {'kept':>7} {'dropped':>8} {'suffix pairs':>13}")
    for floor in (1, 8, 10, 12, 16, 20, 24, 32):
        kept = sum(1 for length in lengths if length >= floor)
        probe = QuickHelpIndex(args.locale, index.by_composed, min_anchor=floor)
        print(f"{floor:>5} {kept:>7} {len(lengths) - kept:>8} {len(probe.suffix_collisions()):>13}")
    return 0


def _cmd_census(args) -> int:
    """Print every number this repository's prose is allowed to quote about the corpus.

    It exists because twelve numbers written into docstrings and documents did not reproduce --
    in a change whose subject is typed values standing where measured ones should be. A number
    that lives in prose is a measurement nobody re-runs; a number printed by a command is one
    anybody can.
    """
    app = args.app
    out = {"logic": app_build(app)}
    for source in sorted(EXTRACTORS):
        rows = list(EXTRACTORS[source](app))
        by_locale = collections.Counter(locale for _u, locale, _k, _f, _v in rows)
        out[source] = {"files": len(corpus_files(app, source)), "entries": len(rows),
                       "locales": dict(sorted(by_locale.items()))}
    encodings = collections.Counter()
    for root, _dirs, files in os.walk(app):
        for name in files:
            if name.endswith(".strings"):
                with open(os.path.join(root, name), "rb") as handle:
                    head = handle.read(8)
                encodings["bplist" if head[:8] == _BPLIST
                          else "utf16-bom" if head[:2] in _BOM_UTF16 else "other"] += 1
    out["strings_encodings"] = dict(encodings)
    suffix = {}
    for locale in EXPECTED_LOCALES:
        index = QuickHelpIndex.from_app(app, locale, min_anchor=DEFAULT_MIN_ANCHOR)
        suffix[locale] = {"compositions": len(index.by_composed),
                          "suffix_pairs": len(index.suffix_collisions())}
    out["quickhelp_suffix_pairs"] = suffix
    out["quickhelp_suffix_pairs_total"] = sum(v["suffix_pairs"] for v in suffix.values())
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def _cmd_status(args) -> int:
    manifest = load_manifest()
    print(f"index pinned to Logic {manifest['logic']['version']} ({manifest['logic']['build']}), "
          f"extractor v{manifest['extractor_version']}")
    if args.app and os.path.isdir(args.app):
        here = app_build(args.app)
        if here != manifest["logic"]:
            print(f"DRIFT: installed Logic is {here['version']} ({here['build']})", file=sys.stderr)
            return 1
        for source, block in sorted(manifest["sources"].items()):
            now = corpus_digest(args.app, corpus_files(args.app, source))
            state = "ok" if now == block["corpus_digest"] else "DRIFT"
            print(f"  {source:10s} {state}")
            if state == "DRIFT":
                return 1
    cited = scan_repo_citations()
    print(f"{len(cited)} citation(s) in the tree")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", default=DEFAULT_APP)
    sub = parser.add_subparsers(dest="command", required=True)

    build_cmd = sub.add_parser("build", help="extract the corpus and pin it (needs Logic)")
    build_cmd.add_argument("--source", action="append", choices=sorted(EXTRACTORS))
    build_cmd.add_argument("--no-citations", action="store_true")
    build_cmd.set_defaults(func=_cmd_build)

    resolve_cmd = sub.add_parser("resolve", help="print the value a reference names")
    resolve_cmd.add_argument("ref")
    resolve_cmd.set_defaults(func=_cmd_resolve)

    locate_cmd = sub.add_parser(
        "locate", help="every place a string is a whole value in Logic, as references (needs Logic)")
    locate_cmd.add_argument("text")
    locate_cmd.add_argument("--app", default=DEFAULT_APP)
    locate_cmd.add_argument("--source", choices=sorted(EXTRACTORS))
    locate_cmd.add_argument("--locale")
    locate_cmd.add_argument("--every", action="store_true",
                            help="one line per locale instead of one per key")
    locate_cmd.set_defaults(func=_cmd_locate)

    check_cmd = sub.add_parser("check", help="refuse unless <ref>=<value> holds offline")
    check_cmd.add_argument("pair", nargs="+")
    check_cmd.set_defaults(func=_cmd_check)

    absent_cmd = sub.add_parser("absent", help="prove a string is not in the pinned corpus")
    absent_cmd.add_argument("source", choices=sorted(EXTRACTORS))
    absent_cmd.add_argument("locale")
    absent_cmd.add_argument("text")
    absent_cmd.set_defaults(func=_cmd_absent)

    axhelp_cmd = sub.add_parser("axhelp", help="reverse AXHelp readings into QuickHelp keys")
    axhelp_cmd.add_argument("--locale", default="ko")
    axhelp_cmd.add_argument("--min-anchor", type=int, default=DEFAULT_MIN_ANCHOR)
    axhelp_cmd.add_argument("value", nargs="?")
    axhelp_cmd.set_defaults(func=_cmd_axhelp)

    thresholds_cmd = sub.add_parser("thresholds", help="what each anchor floor costs and buys")
    thresholds_cmd.add_argument("--locale", default="ko")
    thresholds_cmd.set_defaults(func=_cmd_thresholds)

    census_cmd = sub.add_parser("census", help="every corpus number prose is allowed to quote")
    census_cmd.set_defaults(func=_cmd_census)

    status_cmd = sub.add_parser("status", help="has the pinned corpus drifted from the installed Logic")
    status_cmd.set_defaults(func=_cmd_status)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except CanonError as exc:
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())


# ---------------------------------------------------------------------------
# resolving a live AX string against every canonical source, in order
# ---------------------------------------------------------------------------

#: The `.strings` tables that answer for AX strings QuickHelp does not. Measured: of 28 live AXHelp
#: values with no QuickHelp composition, 27 resolve here and 0 resolve in any other framework --
#: not MAMixer, not MAAccessibility, not MAGUI. The one that resolves nowhere in the bundle is
#: recorded as unresolved rather than attributed to a guess.
LOGIC_STRING_UNITS = (
    "Contents/Frameworks/Logic.framework/Versions/A/Resources/Localizable.strings",
    "Contents/Frameworks/Logic.framework/Versions/A/Resources/ControllerAssignments.strings",
    "Contents/Frameworks/Logic.framework/Versions/A/Resources/ActionBarCustomization.strings",
)

#: Logic separates a control's own label from its key equivalent with a run of spaces -- three in
#: every reading seen. The base string is in the table; the run and the shortcut are added at
#: runtime. So `오토메이션 보기/가리기   A` is `Show/Hide Automation` plus a key equivalent, and a
#: resolver that only tries exact equality reports it as uncitable.
_SHORTCUT_SPLIT = re.compile(r"\s{2,}")

#: printf conversions as they appear in Apple's tables. `%%` is handled before these so a literal
#: percent never becomes a wildcard.
_FORMAT_SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaAn]")


#: A template must carry at least this many non-space literal characters to be usable as evidence.
#:
#: Found by inspection, not by reasoning. Without the floor, `TrackInspector_Default_Value_Paramter_
#: FormatString` -- whose whole value is `%1$@ %2$@` -- matches ANY string containing a space, and
#: it duly "resolved" the one live AXHelp value an exhaustive byte scan of the whole bundle could
#: not find: `이 버튼을 누르면 윈도우를 확대/축소합니다.` became arguments `['이', '버튼을 …']`.
#: That is a citation manufactured out of nothing, in a module whose entire purpose is to refuse
#: exactly that, and it turned a 113-of-114 measurement into a false 114-of-114.
MIN_TEMPLATE_LITERAL = 4

#: ...and the floor alone is not enough, because literal text does not have to be SHARED OUT.
#: Measured in the shipped bundle by review 2026-09-15: `"%d-bit %@ %@ %@"` clears a four-character
#: floor on the strength of `-bit` and then matches `24-bit <anything> <anything> <anything>` --
#: three unconstrained captures behind one hyphenated word. So the literal must also scale with the
#: number of conversions. Three non-space characters per conversion rejects that template (4 < 12)
#: and keeps `%@ 채널 스트립 표시` (7 >= 3), which is the one that renders eight live values.
MIN_LITERAL_PER_CONVERSION = 3


def template_to_regex(template: str) -> re.Pattern | None:
    """Compile a printf-style canonical string into a matcher for the value it renders to.

    Returns None when the template has no conversions -- an exact string is not a template, and
    treating it as one would make `.*` out of nothing -- and also when what remains after the
    conversions is too thin to identify anything. See `MIN_TEMPLATE_LITERAL`.
    """
    if not _FORMAT_SPEC.search(template):
        return None
    conversions = len(_FORMAT_SPEC.findall(template))
    literal = len(re.sub(r"\s+", "", _FORMAT_SPEC.sub("", template)))
    if literal < MIN_TEMPLATE_LITERAL or literal < MIN_LITERAL_PER_CONVERSION * conversions:
        return None
    out, last = [], 0
    for spec in _FORMAT_SPEC.finditer(template):
        out.append(re.escape(template[last:spec.start()]))
        out.append(r"(.+?)" if spec.group(0).endswith(("@", "s", "S")) else r"([-+0-9.,eE]+)")
        last = spec.end()
    out.append(re.escape(template[last:]))
    return re.compile("^" + "".join(out) + "$", re.DOTALL)


class Resolution:
    """One live AX string, traced back to the canonical bytes that produced it."""

    __slots__ = ("source", "unit", "locale", "_key", "field", "tier", "prefix", "suffix",
                 "arguments", "canonical", "keys")

    def __init__(self, *, source, unit, locale, key, field, tier, canonical,
                 prefix="", suffix="", arguments=(), keys=None):
        self.source, self.unit, self.locale = source, unit, locale
        self._key, self.field, self.tier = key, field, tier
        self.canonical, self.prefix, self.suffix = canonical, prefix, suffix
        self.arguments = tuple(arguments)
        self.keys = tuple(keys) if keys else (key,)

    @property
    def key(self):
        """The single key this value names, or None when several share the string.

        `AXHelpMatch.key` has refused to pick one since it was written -- "picking one of them
        would manufacture a precision the data does not have" -- and `AXStringResolver.resolve`
        then wrote `key=match.keys[0]` anyway, as did `StringsIndex.lookup` with `hits[0]`. The
        named site and the enforcement site disagreed inside one file. Measured: 11 of 114 live
        values resolve to more than one key, and `드래그 모드` to four.
        """
        return self._key if len(self.keys) == 1 else None

    @property
    def ref(self) -> str:
        """The reference for the single key, or None when the value names several."""
        return (str(CanonRef(self.source, self.unit, self.locale, self.keys[0], self.field))
                if len(self.keys) == 1 else None)

    def refs(self) -> list:
        """Every key this value could name. The honest shape when the string is shared."""
        return [str(CanonRef(self.source, self.unit, self.locale, key, self.field))
                for key in self.keys]

    def as_dict(self) -> dict:
        return {"source": self.source, "unit": self.unit, "locale": self.locale,
                "key": self.key, "keys": list(self.keys), "refs": self.refs(), "field": self.field,
                "tier": self.tier, "prefix": self.prefix, "suffix": self.suffix,
                "arguments": list(self.arguments), "ref": self.ref,
                "canonical": self.canonical}


class StringsIndex:
    """One or more `.strings` tables for a locale, indexed for exact, shortcut and template hits."""

    __slots__ = ("locale", "by_value", "templates")

    def __init__(self, locale: str, by_value: dict, templates: list):
        self.locale, self.by_value, self.templates = locale, by_value, templates

    @classmethod
    def from_app(cls, app: str, locale: str, units=LOGIC_STRING_UNITS) -> "StringsIndex":
        by_value: dict[str, list[tuple[str, str]]] = {}
        templates: list[tuple[re.Pattern, str, str, str]] = []
        for unit in units:
            head, tail = os.path.split(unit)
            path = os.path.join(app, head, f"{locale}.lproj", tail)
            if not os.path.exists(path):
                # Measured and expected: ControllerAssignments and ActionBarCustomization ship in
                # nine locales and not in en, because en reads the nib directly. A missing table is
                # therefore a fact about the bundle, not a failure -- but a missing table for a
                # locale that should have one shows up as a smaller corpus, so `build` counts them.
                continue
            with open(path, "rb") as handle:
                table = parse_strings(handle.read(), path=path)
            for key, value in table.items():
                folded = normalize(value)
                if not folded:
                    continue
                by_value.setdefault(folded, []).append((unit, key))
                pattern = template_to_regex(folded)
                if pattern is not None:
                    templates.append((pattern, unit, key, folded))
        for entries in by_value.values():
            entries.sort()
        # Longest template first: a more specific one must win over `%@`-only noise.
        templates.sort(key=lambda row: -len(row[3]))
        return cls(locale, by_value, templates)

    def lookup(self, value: str) -> Resolution | None:
        folded = normalize(value)
        hits = self.by_value.get(folded)
        if hits:
            unit, key = hits[0]
            return Resolution(source="strings", unit=unit, locale=self.locale, key=key,
                              field="value", tier="exact", canonical=folded,
                              keys=[k for _, k in hits])

        # A key equivalent appended after a run of spaces: `오토메이션 보기/가리기   A`. The base is
        # in the table and the run plus the shortcut are added at runtime, so try every run of two
        # or more spaces as a possible boundary. Walk them from the LAST to the FIRST, which keeps
        # as much of the label as possible for a label that itself contains a double space.
        boundaries = list(_SHORTCUT_SPLIT.finditer(folded))
        for span in reversed(boundaries):
            base, tail = normalize(folded[:span.start()]), folded[span.end():]
            if not base or not tail:
                continue
            hits = self.by_value.get(base)
            if hits:
                unit, key = hits[0]
                return Resolution(source="strings", unit=unit, locale=self.locale, key=key,
                                  field="value", tier="shortcut", canonical=base,
                                  suffix=tail, keys=[k for _, k in hits])

        # Every template, not the first that matches. `templates` is sorted by length and the
        # first hit used to win, which is an arbitrary choice between two templates of similar
        # specificity -- the same manufacture `AXHelpMatch.key` refuses when a composition is
        # shared. Measured in ko: 27 templates render another canonical value outright, and no
        # live value matches two. So this refuses a hazard rather than a known failure, which is
        # the moment to refuse it.
        hits = [(pattern.match(folded), unit, key, template)
                for pattern, unit, key, template in self.templates]
        hits = [hit for hit in hits if hit[0]]
        if len(hits) != 1:
            return None
        found, unit, key, template = hits[0]
        return Resolution(source="strings", unit=unit, locale=self.locale, key=key,
                          field="value", tier="template", canonical=template,
                          arguments=found.groups())


class AXStringResolver:
    """Trace a live AX string to Logic's own data, trying the sources in a fixed order.

    The order is the policy this repository now runs on: canonical data first, and a runtime
    measurement only for what no canonical source can answer. QuickHelp goes first because it
    identifies a CONTROL; the framework tables go second because they identify a STRING, which is
    weaker -- the same label is reused across the interface. A value that survives both is what
    `canon_absent` is for.
    """

    def __init__(self, app: str, locale: str, *, min_anchor: int = DEFAULT_MIN_ANCHOR):
        self.locale = locale
        self.quickhelp = QuickHelpIndex.from_app(app, locale, min_anchor=min_anchor)
        self.strings = StringsIndex.from_app(app, locale)

    def resolve(self, value: str) -> Resolution | None:
        """QuickHelp's WHOLE and SUFFIX matches, then the framework tables, then truncation.

        The order matters and the first version got it wrong. `truncated` is the weakest tier --
        it infers a key from a value that is a PREFIX of a composition -- and running it before the
        framework tables let it claim eight live values that were not truncated at all. They were
        short, complete `.strings` labels: `모든 채널 스트립 보기` (12 characters) and
        `트랙에서 사용하는 모든 채널 스트립 보기` (22) are two distinct menu items, and both were
        assigned `CSS_016_ChannelStriipViewMenu` -- which is the popup MENU that contains them.
        A wrong canonical key that resolves and digest-matches is the failure this whole axis is
        the parable for. Measured by review 2026-09-15.

        So truncation is tried only when nothing else can explain the value at all.
        """
        match = self.quickhelp.parse_axhelp(value, allow_truncated=False)
        if match is not None:
            return self._from_match(match)
        found = self.strings.lookup(value)
        if found is not None:
            return found
        match = self.quickhelp.parse_axhelp(value)
        return self._from_match(match) if match is not None else None

    def _from_match(self, match) -> Resolution:
        return Resolution(source="quickhelp", unit=match.source_unit, locale=self.locale,
                          key=match.keys[0], field="composed", tier=match.tier,
                          canonical=match.composed, prefix=match.prefix, keys=match.keys)
