#!/usr/bin/env python3
"""What Apple's own corpus says a label reads in a locale -- the one rule an unattended run may apply.

A census can disagree with the ledger in two ways that need a decision: a label's reading CHANGED
(the same variant, other text) or a NEW VARIANT turned up (a string where the label's canonical sits
in the other language's census). Whether to take either used to be a person's judgement, and a person
is not there at 03:00. The only judgement that can be made without one is an EQUALITY:

    ACCEPT   the live string EXACTLY equals a value the label's own canon rows
             (`derivedFrom`, `alsoDerivedFrom` in AXLocalePolicy.swift) carry in that locale in the
             pinned corpus. Apple's bytes and Logic's screen agree, byte for byte.
    HOLD     everything else: a different row's value, a containment hit, a row that cannot be
             resolved, a corpus that is not the pinned build. Recorded with its reason in
             docs/locale/holds.json and never applied.

Reading the corpus needs the installed Logic, and the installed Logic must BE the build the committed
canon pins -- otherwise "the canon value" is a reading of another release and the equality proves
nothing. `values_for` refuses (raises `CorpusUnavailable`) rather than answer from a mismatched app.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

_CODE = {"en-US": "en", "ja-JP": "ja", "de-DE": "de", "es-ES": "es", "fr-FR": "fr", "it-IT": "it",
         "pt-BR": "pt", "zh-CN": "zh_CN", "zh-TW": "zh_TW", "ko-KR": "ko"}


class CorpusUnavailable(Exception):
    """The canon cannot be read here, or is not the pinned build. Never answered from a guess."""


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Corpus:
    """The pinned corpus of the installed Logic, read lazily and once per source."""

    def __init__(self, repo=REPO, app=None, canon=None, derived=None, swift_text=None):
        self.repo = repo
        self.canon = canon or _load("lcv_canon", os.path.join(repo, "Scripts", "logic_canon.py"))
        self.derived = derived or _load("lcv_derived", os.path.join(repo, "Scripts", "check-labelsets-are-derived.py"))
        self.app = app or self.canon.DEFAULT_APP
        self.manifest = self.canon.load_manifest()
        here = self.canon.app_build(self.app)
        pinned = self.manifest.get("logic")
        if not here or here != pinned:
            raise CorpusUnavailable(f"the installed Logic {here} is not the build the canon pins {pinned}")
        if swift_text is None:
            path = os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
            with open(path, encoding="utf-8") as handle:
                swift_text = handle.read()
        self.rows_of = {name: refs for name, _m, refs, _o in self.derived.derivations(swift_text)}
        self.namespace_of = {s: self.canon.TRANSLATION_NAMESPACE.get(s, s) for s in self.manifest["sources"]}
        self._cache = {}

    def _units(self, source):
        if source not in self._cache:
            self._cache[source] = list(self.canon.EXTRACTORS[source](self.app))
        return self._cache[source]

    def values_for(self, label, locale):
        """`(values, why)`: every value the label's rows carry in `locale`, and why it may be empty."""
        code = _CODE[locale]
        refs = self.rows_of.get(label) or []
        if not refs:
            return set(), "the label names no canon row (no derivedFrom) to compare against"
        found = set()
        for text in refs:
            ref = self.canon.CanonRef.parse(text)
            namespace = self.namespace_of.get(ref.source, ref.source)
            for source, ns in self.namespace_of.items():
                if ns != namespace:
                    continue
                found |= {v for (u, l, k, f, v) in self._units(source)
                          if u == ref.unit and l == code and k == ref.key and f == ref.field}
        if not found:
            return set(), f"the label's canon row(s) {refs} carry no value in {code}"
        return found, ""


def verdict(corpus, label, locale, live):
    """`("ACCEPT"|"HOLD", reason)` for a live string against the label's own canon value in `locale`."""
    if not isinstance(live, str) or not live:
        return "HOLD", "there is no live string to compare"
    values, why = corpus.values_for(label, locale)
    if not values:
        return "HOLD", why
    if live in values:
        return "ACCEPT", f"the live string is exactly the label's own canon value in {locale}"
    return "HOLD", (f"the live string {live!r} is not a value of the label's own canon row(s) in "
                    f"{locale}: {sorted(values)}")
