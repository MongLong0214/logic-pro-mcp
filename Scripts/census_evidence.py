#!/usr/bin/env python3
"""Census evidence, stored one row per line.

A census is every AX element Logic showed, as rows. Pretty-printed that is ten thousand lines per locale
and a diff nobody can read; as JSON Lines it is one line per ROW, the header on the first line, and
`git diff` shows exactly the rows that changed.

    {"format": "census-jsonl/1", "host": {...}, "kind": "navigation-free", "menu_bar": [...], "rows": N}
    {"surface": ..., "path": ..., "role": ..., ...}        <- N of these, in census order

The files are stored in Git LFS (`.gitattributes`), which checks out the real bytes; a checkout that did not
fetch them holds a three-line pointer, and `loads` says so instead of failing on a row.

`rows` is stated in the header so a truncated file is refused rather than read short. The BYTES of the file
are what a record binds: `locale_labels.record_facts` hashes the cited evidence file as it is, so editing a
single row, or the header, changes `record_sha256` and every reading resting on it stops verifying.

    load(path)             a census document {"host", "menu_bar", "kind", "census": [rows]} from a `.jsonl`
                           or a legacy `.json` evidence file; ValueError when the file is not one
    dumps(doc)             the JSONL text of a census document
    EXTENSIONS             the suffixes that name census evidence
"""
import json

FORMAT = "census-jsonl/1"
EXTENSIONS = (".census.jsonl", ".census.json")


def dumps(doc):
    """The census document as JSONL text: header line, then one line per row, trailing newline."""
    rows = doc["census"]
    header = {"format": FORMAT, "host": doc["host"], "kind": doc.get("kind") or "navigation-free",
              "menu_bar": doc.get("menu_bar") or [], "rows": len(rows)}
    lines = [json.dumps(header, ensure_ascii=False, sort_keys=True, separators=(",", ":"))]
    lines += [json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for row in rows]
    return "\n".join(lines) + "\n"


def loads(text):
    if text.startswith("version https://git-lfs.github.com/spec/"):
        raise ValueError("this census evidence is a Git LFS pointer, not the rows: the checkout did not fetch LFS "
                         "(`git lfs pull`, or `lfs: true` on actions/checkout)")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise ValueError("empty census file")
    header = json.loads(lines[0])
    if not isinstance(header, dict) or header.get("format") != FORMAT:
        raise ValueError(f"not a {FORMAT} header")
    rows = [json.loads(line) for line in lines[1:]]
    if header.get("rows") != len(rows):
        raise ValueError(f"the header says {header.get('rows')} rows and the file holds {len(rows)}")
    return {"host": header["host"], "kind": header.get("kind"), "menu_bar": header.get("menu_bar") or [],
            "census": rows}


def load(path):
    """A census document from `path`, whichever of the two formats it is in."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if str(path).endswith(".jsonl"):
        return loads(text)
    return json.loads(text)


def is_census_file(name):
    return str(name).endswith(EXTENSIONS)
