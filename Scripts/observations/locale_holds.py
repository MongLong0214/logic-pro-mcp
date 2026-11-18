#!/usr/bin/env python3
"""The committed list of everything a campaign did NOT apply, with the reason.

`docs/locale/holds.json` is written by the tools, never by hand. A run that declines to take a reading
(a changed string that is not the label's own canon value, a new variant the canon does not vouch for, a
label whose element role no census row names) records it here, so the decision is a file a reviewer can
read rather than a line in a log that scrolled away. Each locale owns one section and a re-run REPLACES
it: a hold that no longer applies disappears, and a hold that still applies is rewritten identically.

    {"schema": 1, "roles": {label: {roles, basis, census_locale}},
     "holds": {locale: {"changed": {label: {...}}, "new_variant": {label: {...}},
                        "role_undeclared": {label: reason}, "unconfirmed": {label: {...}}}}}
"""
import json
import os

KINDS = ("changed", "new_variant", "role_undeclared", "unconfirmed")


def path(repo):
    return os.path.join(repo, "docs", "locale", "holds.json")


def load(repo):
    try:
        with open(path(repo), encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        doc = {}
    doc.setdefault("schema", 1)
    doc.setdefault("note", "Written by Scripts/observations/locale_holds.py; never by hand. A hold is a "
                           "reading a campaign declined to apply, and why.")
    doc.setdefault("roles", {})
    doc.setdefault("holds", {})
    return doc


def save(repo, doc):
    target = path(repo)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    text = json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def record(repo, locale, sections, declared_roles=None, narrowed_roles=None):
    """Replace `locale`'s section with `sections` (`{kind: {label: detail}}`); merge declared roles."""
    for kind in sections:
        if kind not in KINDS:
            raise ValueError(f"unknown hold kind {kind!r}; known: {KINDS}")
    doc = load(repo)
    cleaned = {kind: dict(sorted(items.items())) for kind, items in sections.items() if items}
    if cleaned:
        doc["holds"][locale] = dict(sorted(cleaned.items()))
    else:
        doc["holds"].pop(locale, None)
    if declared_roles:
        doc["roles"].update(declared_roles)
    if narrowed_roles:
        doc.setdefault("roles_narrowed", {}).update(narrowed_roles)
        doc["roles_narrowed"] = dict(sorted(doc["roles_narrowed"].items()))
    doc["roles"] = dict(sorted(doc["roles"].items()))
    doc["holds"] = dict(sorted(doc["holds"].items()))
    save(repo, doc)
    return doc


def counts(repo):
    """`{locale: {kind: n}}`, for the one-line JSON a campaign prints."""
    doc = load(repo)
    return {loc: {k: len(v) for k, v in sec.items()} for loc, sec in doc["holds"].items()}
