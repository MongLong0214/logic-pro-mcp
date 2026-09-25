#!/usr/bin/env python3
"""Every locale on the axis is one a record's generated `host` block can name.

`observation_host.py` turns the language Logic runs in into the spelling of `host.locale`, and
`check-observation-records.py` refuses a record whose locale is not on the axis. Until #977 that
mapping was a typed table of four languages, so a record taken on a Spanish, French, Italian,
Portuguese or Chinese Logic was refused for a correct reading. The ids below are the ones a language
switch writes (`defaults write com.apple.logic10 AppleLanguages -array <id>`), which for Chinese is
a script and not a region.

    python3 Scripts/test_observation_host.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import observation_host as H  # noqa: E402

SWITCH_IDS = {"en": "en-US", "ko": "ko-KR", "ja": "ja-JP", "de": "de-DE", "es": "es-ES",
              "fr": "fr-FR", "it": "it-IT", "pt": "pt-BR", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW"}


def main():
    failures = []
    axis = H.axis_locales()
    if sorted(SWITCH_IDS.values()) != sorted(axis):
        failures.append(f"the axis is {sorted(axis)}, but this test switches Logic into "
                        f"{sorted(SWITCH_IDS.values())} -- add the new locale's language id here")
    for language, expected in SWITCH_IDS.items():
        got = H.axis_locale(language, axis)
        if got != expected:
            failures.append(f"Logic language {language!r} maps to {got!r}, not {expected!r}")
    # A language that names two axis locales, or none, is not guessed: the record keeps the raw id
    # and the record guard refuses it.
    for language in ("zh", "nl"):
        got = H.axis_locale(language, axis)
        if got is not None:
            failures.append(f"Logic language {language!r} maps to {got!r}; it names no single "
                            f"axis locale and must map to None")
    for failure in failures:
        print("FAIL", failure)
    print(f"{len(SWITCH_IDS) + 2 - len(failures)} checks passed" if not failures else "")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
