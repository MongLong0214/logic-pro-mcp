#!/usr/bin/env python3
"""Which Logic release is current. One parser of one declaration.

`AXLocalePolicy.currentLogicVersion` and `AXLocalePolicy.currentLogicBuild` in Swift are the ONLY
declaration of the Logic this repository is judged against. Everything that needs the answer -- the
ledger generator, the ratchets, the observation-record guard, the canon guard -- reads it through
`declared_logic` here, so there is one parser and no file that carries the number a second time.

Imports nothing from this repository on purpose: the guards that use it run against fixture trees
whose layout is not the real one, and a module that reads its own repository at import time cannot be
loaded there.
"""
import os
import re

SWIFT_RELATIVE = os.path.join("Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
_VERSION = re.compile(r'static let currentLogicVersion\s*=\s*"([^"]*)"')
_BUILD = re.compile(r'static let currentLogicBuild\s*=\s*"([^"]*)"')


def declared_logic(swift_path):
    """`{"app", "version", "build"}` the Swift declares as the current Logic, or None without one.

    Exactly one declaration of each, or it raises ValueError: two `currentLogicVersion` lines is two
    authorities, and taking the first would make the ledger's currency depend on which one a regex met.
    """
    try:
        with open(swift_path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return None
    versions, builds = _VERSION.findall(text), _BUILD.findall(text)
    if not versions and not builds:
        return None
    if len(versions) != 1 or len(builds) != 1 or not versions[0].strip() or not builds[0].strip():
        raise ValueError(f"{swift_path}: needs exactly one non-empty `currentLogicVersion` and one "
                         f"`currentLogicBuild`, found {len(versions)} and {len(builds)}")
    return {"app": "Logic Pro", "version": versions[0].strip(), "build": builds[0].strip()}


def release_key(version, build):
    """`(version parts, build parts)` as numbers, so 12.4 is later than 12.3 and 13.0 than both."""
    def parts(text):
        return tuple(int(piece) if piece.isdigit() else 0
                     for piece in re.split(r"[.\-]", str(text or "")))
    return (parts(version), parts(build))
