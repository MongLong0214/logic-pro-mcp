"""The evidence document of the fixed verifier (ADR-027 D2, D7): what a run stores, and how.

Named `evidence_doc`, not `evidence`, so it never shadows `Scripts/livekit/evidence.py` for a script
that has both directories on its path.

FORMAT `lpm-evidence/1`
-----------------------
    {
      "format": "lpm-evidence/1",
      "spec_path": "docs/acceptance/1020.json",
      "spec": { ...the acceptance document, embedded whole... },
      "spec_sha256": "<sha256 of canonical_bytes(spec)>",
      "binary": {                        # the names Scripts/verify/live/binary.py build() returns
        "binary_path": "<absolute path>" | null,
        "binary_sha256": "<64 hex>" | null,
        "head": "<40 hex>" | null,
        "binding": "built-by-verifier" | "unbound",
        "note": "<how the binding was established, or why it was not>"
      },
      "runs": {
        "<locale>": {
          "date": "YYYY-MM-DD",          # when this locale was run; read by `record`
          "host": {...} | null,          # Scripts/observation_host.py's block, measured by the runner
          "locale_reading": {...} | null,  # Scripts/verify/live/locale.py reading(<locale>), taken
                                         # after the switch: {lproj, code, expected_title,
                                         # language_setting, window_names}
          "rows": {
            "<row id>": {
              "observations": {
                "<bound name>": {"step": {...}, "raw": "<exact JSON text>", "raw_bytes": <int>}
                              | {"step": {...}, "unreadable": "<why the runner could not read>"}
              }
            }
          }
        }
      },
      "verdicts": {"<locale>": {"<row id>": {...engine.evaluate_row output...}}}
    }

The predicates are not copied beside each observation: they are the embedded spec's rows, bound to
this document by `spec_sha256`, which the engine recomputes before it reads anything else.

WHAT MAKES TRUNCATION VISIBLE
-----------------------------
`raw` is the probe's or server's text as received, and `raw_bytes` is its UTF-8 length taken from
the same string at the same moment. The engine parses `raw` itself at judgement time -- there is no
stored parsed copy to disagree with it -- and a `raw` whose length is not `raw_bytes` is
UNREADABLE. Audit A found observations cut at 400 characters (`repr(...)[:400]`) and replies kept
as six envelope keys; nothing in this module shortens a value, and the engine can tell when
something else did.

A FILE CANNOT ATTEST TO HOW IT WAS MADE
---------------------------------------
Every field below is written by whoever writes the file, so none of them can make a document
clean. `binding` can only lower a verdict: "built-by-verifier" is what P0b writes after building
the binary itself from a clean detached checkout of `head`, and anything else can never be clean.
The engine's host checks (re-hash `binary_path` against `binary_sha256`; `head` names a commit of
the repository) are consistency checks: a disagreement counts against the document, and agreement
grants nothing. A run's key is checked against its `locale_reading`: a run filed under `en` whose
reading says Logic was in Korean is refused, and a run with no reading is at best incomplete. But
a stored reading is a claim. Clean needs `engine.Attestation`, held in process by the run that
produced the document (engine.py, "WHO CAN CERTIFY CLEAN").

Writes are atomic: a temporary file in the destination directory, fsync, then `os.replace`.
"""
from __future__ import annotations

import hashlib
import json
import os
import tempfile

FORMAT = "lpm-evidence/1"
BOUND = "built-by-verifier"
UNBOUND = "unbound"

# The evidence format's field names, in one place. The binary block uses the names
# Scripts/verify/live/binary.py build() returns, so P0b stores its result without renaming.
BINARY_PATH, BINARY_SHA256, HEAD, BINDING = "binary_path", "binary_sha256", "head", "binding"
LOCALE_READING = "locale_reading"

#: lproj -> the AppleLanguages code Logic is given for it. The same table as
#: Scripts/verify/live/locale.py CODES (P0b); the engine checks a run's reading against it.
LOCALE_CODES = {"de": "de", "en": "en", "es": "es", "fr": "fr", "it": "it", "ja": "ja", "ko": "ko",
                "pt": "pt-BR", "zh_CN": "zh-CN", "zh_TW": "zh-TW"}


def canonical_bytes(obj) -> bytes:
    """The one serialization every digest in the verifier is taken over."""
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sha256_of(obj) -> str:
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


def sha256_of_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_of_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_observation(step: dict, raw_text: str) -> dict:
    """An observation as the runner received it. `raw_text` is stored whole."""
    if not isinstance(raw_text, str):
        raise TypeError("raw_text is the exact text received, as str")
    return {"step": step, "raw": raw_text, "raw_bytes": len(raw_text.encode("utf-8"))}


def unreadable_observation(step: dict, reason: str) -> dict:
    """An observation the runner could not take. Never a default value in its place."""
    if not reason:
        raise ValueError("an unreadable observation says why")
    return {"step": step, "unreadable": reason}


def new_document(spec: dict, spec_path: str, binary: dict) -> dict:
    """An empty evidence document for one spec and one binary; runs and verdicts are filled later."""
    return {
        "format": FORMAT,
        "spec_path": spec_path,
        "spec": spec,
        "spec_sha256": sha256_of(spec),
        "binary": binary,
        "runs": {},
        "verdicts": {},
    }


def _refuse_duplicate_keys(pairs: list) -> dict:
    """The object_pairs_hook of every spec and evidence read. JSON keeps the last of two equal keys
    silently, so a document could say one thing to a reader of its text and another to the engine
    (`"locales": "all"` then `"locales": {...}`). A duplicate is refused, naming the key."""
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"key {key!r} appears twice in one object; JSON would keep the last one "
                             f"silently, so the document is refused rather than read")
        out[key] = value
    return out


def loads(text: str):
    """Parse a spec or evidence document's text, refusing a duplicate key (ValueError)."""
    return json.loads(text, object_pairs_hook=_refuse_duplicate_keys)


def load(path: str) -> dict:
    """Read an evidence (or acceptance) document. Raises OSError or ValueError, including for a key
    that appears twice in one object; callers map both to a refusal rather than to an empty
    document."""
    with open(path, encoding="utf-8") as handle:
        doc = loads(handle.read())
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: the top level is {type(doc).__name__}, not an object")
    return doc


def serialize(doc) -> bytes:
    """The bytes a document is written as."""
    return (json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=False) + "\n").encode("utf-8")


def write_atomic(path: str, doc) -> None:
    """Write JSON so that a reader sees the old file or the new one, never half of either."""
    write_bytes_atomic(path, serialize(doc))


def write_bytes_atomic(path: str, data: bytes) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def publish_content_addressed(directory: str, data: bytes) -> str:
    """Write `data` as `<directory>/<sha256>.json` and return that name. The name IS the content,
    so a later file can never take an earlier one's name: a record that cites it cites these bytes."""
    name = f"{sha256_of_bytes(data)}.json"
    path = os.path.join(directory, name)
    if os.path.exists(path):
        with open(path, "rb") as handle:
            if handle.read() == data:
                return name
    write_bytes_atomic(path, data)
    return name
