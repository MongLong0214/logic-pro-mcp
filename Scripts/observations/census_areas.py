#!/usr/bin/env python3
"""The names Logic gives the main window's areas, per locale, read from Apple's own strings.

A census row's `path` passes through the area it sits in, and that area's name is a localised string:
`AXToolbar[Control Bar]`, `AXGroup[Mezclador]`, `AXGroup[Cabecera de Pistas]`. Which surface a row is
filed under is decided by those names, so the names have to be Apple's -- read from the row they come
from -- and not spellings somebody typed after reading one census. A hand-typed list covered four
locales and left 526 to 537 rows unfiled in each of the other six.

    census_areas.py --write     regenerate docs/locale/census-areas.json from the installed Logic
    census_areas.py --check     exit 1 unless the committed file is what the installed Logic would write
                                (a machine with no Logic, or another build, is a skip and exits 0)

Two kinds of row. A PLAIN row is the name itself (`StrTabBtnLabel|||Control Bar`). A COMPOSED row is a
format Logic fills with the Tracks area's name: `%@ header` is `Cabecera de %@` in Spanish and `En-tête
%@` in French, which is why `Cabecera de Pistas` and `En-tête Pistes` are the names of the Tracks header
and not strings anybody had to guess. The result is checked against every locale's real census by
`Scripts/test_locale_census.py`: each name must occur as a bracketed path segment in that locale's
evidence, or the derivation is wrong for that locale and the test says so.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
JSON_PATH = os.path.join(REPO, "docs", "locale", "census-areas.json")
LOGIC_STRINGS = "Contents/Frameworks/Logic.framework/Versions/A/Resources/Localizable.strings"

#: area -> ((row key in Logic's Localizable.strings, ...), composed). Composed rows are filled with
#: `tracks`. An area may be named by more than one row: Logic draws a control bar's AX description from
#: `Control Bar#acc`, which Portuguese spells `Barra de Controle`, while its tab label
#: `StrTabBtnLabel|||Control Bar` is `Barra de Controles`. Both are Apple's, and the census says which one
#: the tree uses, so both are names.
ROWS = {
    "tracks":            (("StrTabBtnLabel|||Tracks",), False),
    "control_bar":       (("StrTabBtnLabel|||Control Bar", "Control Bar#acc"), False),
    "mixer":             (("StrTabBtnLabel|||Mixer", "Mixer#acc"), False),
    "library":           (("StrTabBtnLabel|||Library", "Library#acc"), False),
    "event":             (("StrTabBtnLabel|||Event",), False),
    "marker":            (("StrTabBtnLabel|||Marker",), False),
    "tempo":             (("StrTabBtnLabel|||Tempo",), False),
    "signature":         (("StrTabBtnLabel|||Signature",), False),
    "inspector":         (("Inspector", "Inspector#acc"), False),
    "transport_display": (("Transport Display",), False),
    "playhead_position": (("Playhead Position",), False),
    "header":            (("%@ header",), True),
    "contents":          (("%@ contents",), True),
    "legend":            (("%@ legend",), True),
    "time_ruler":        (("%@ time ruler",), True),
}
CODES = {"en-US": "en", "ko-KR": "ko", "ja-JP": "ja", "de-DE": "de", "es-ES": "es", "fr-FR": "fr",
         "it-IT": "it", "pt-BR": "pt", "zh-CN": "zh_CN", "zh-TW": "zh_TW"}

_CACHE = {}


def load(path=JSON_PATH):
    """`{locale: {area: name}}` as committed, or {} when the file is absent."""
    if path not in _CACHE:
        try:
            with open(path, encoding="utf-8") as handle:
                _CACHE[path] = json.load(handle).get("locales") or {}
        except (OSError, ValueError):
            _CACHE[path] = {}
    return _CACHE[path]


def names(locale=None, path=JSON_PATH):
    """`{area: [names]}` for one locale, or for every locale together when `locale` is None.

    Several locales together is the answer for a caller that has no locale (an old census file): a name
    from another language cannot occur in this one's tree, and where two languages spell an area alike
    (`Mixer`, `Inspector`) the two agree about which surface it is.
    """
    table = load(path)
    out = {}
    for loc, areas in sorted(table.items()):
        if locale is not None and loc != locale:
            continue
        for area, found in areas.items():
            out.setdefault(area, [])
            for name in found:
                if name not in out[area]:
                    out[area].append(name)
    return out


def derive(corpus):
    """The document for the installed Logic: every area name in every locale, with its source row."""
    rows = {}
    for (unit, loc, key, field, value) in corpus._units("strings"):
        if unit == LOGIC_STRINGS and field == "value":
            rows.setdefault(key, {})[loc] = value
    locales = {}
    for locale, code in CODES.items():
        tracks = rows.get(ROWS["tracks"][0][0], {}).get(code)
        entry = {}
        for area, (keys, composed) in ROWS.items():
            found = []
            for key in keys:
                value = rows.get(key, {}).get(code)
                if value is None:
                    continue
                value = value.replace("%@", tracks) if composed else value
                if value not in found:
                    found.append(value)
            if not found or (composed and tracks is None):
                raise ValueError(f"{locale}: Apple's strings carry none of the rows {keys!r}")
            entry[area] = found
        locales[locale] = dict(sorted(entry.items()))
    return {
        "schema": 1,
        "note": "Generated by Scripts/observations/census_areas.py --write from the installed Logic's "
                "Localizable.strings; never edited by hand. The names Logic gives the main window's "
                "areas, which decide the surface a census row is filed under. The release it was read "
                "from is the one the canon manifest pins (the current Logic is declared once, in "
                "AXLocalePolicy.swift, and not restated here).",
        "source": LOGIC_STRINGS,
        "rows": {area: {"keys": list(keys), "composed_with": "tracks" if composed else None}
                 for area, (keys, composed) in sorted(ROWS.items())},
        "locales": dict(sorted(locales.items())),
    }


def render(doc):
    return json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def main(argv):
    sys.path.insert(0, HERE)
    import locale_canon_value as cv
    try:
        corpus = cv.Corpus(REPO)
    except cv.CorpusUnavailable as exc:
        if "--check" in argv:
            print(f"skip: {exc}")
            return 0
        print(f"REFUSED: {exc}")
        return 2
    text = render(derive(corpus))
    if "--write" in argv:
        os.makedirs(os.path.dirname(JSON_PATH), exist_ok=True)
        with open(JSON_PATH, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        print(f"wrote {os.path.relpath(JSON_PATH, REPO)}")
        return 0
    try:
        current = open(JSON_PATH, encoding="utf-8").read()
    except OSError:
        current = None
    if current != text:
        print(f"{os.path.relpath(JSON_PATH, REPO)} is not what the installed Logic would write; "
              f"run census_areas.py --write")
        return 1
    print("census-areas.json matches the installed Logic")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
