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
      "binary": {
        "sha256": "<64 hex>",
        "head": "<40 hex>",
        "binding": "built-by-verifier" | "unbound",
        "note": "<how the binding was established, or why it was not>"
      },
      "runs": {
        "<locale>": {
          "date": "YYYY-MM-DD",          # when this locale was run; read by `record`
          "host": {...} | null,          # Scripts/observation_host.py's block, measured by the runner
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

`binding` is the one field the engine takes from the runner, and it can only lower a verdict:
"built-by-verifier" is what P0b writes after building the binary itself from a clean detached
checkout of `head`; anything else can never be clean (engine.judge exits 3).

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


def canonical_bytes(obj) -> bytes:
    """The one serialization every digest in the verifier is taken over."""
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sha256_of(obj) -> str:
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


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


def load(path: str) -> dict:
    """Read an evidence (or acceptance) document. Raises OSError or ValueError; callers map both
    to a refusal rather than to an empty document."""
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: the top level is {type(doc).__name__}, not an object")
    return doc


def write_atomic(path: str, doc) -> None:
    """Write JSON so that a reader sees the old file or the new one, never half of either."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, ensure_ascii=False, indent=1, sort_keys=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
