#!/usr/bin/env python3
"""JSON that a reviewer can read and a diff can count: structure on separate lines, leaves on one.

`json.dumps(indent=N)` puts every element of every list on its own line, so a record that lists six
hundred strings, or a ledger entry with a twelve-field provenance block, costs hundreds of lines for
what is one fact each. Here a LEAF -- a scalar, a list of scalars, or a flat object whose values are
scalars or lists of scalars -- is written on ONE line, and everything above a leaf keeps one line per
key or element. The output is ordinary JSON: any reader that parses JSON reads it, key order is the
document's own, and `dumps` is deterministic, so a generator can compare its bytes to a committed file.

    compact_json.dumps(doc)            the text, with a trailing newline
    compact_json.dumps(doc, indent=2)  the same, with a wider indent
"""
import json

_SCALARS = (str, int, float, bool, type(None))


def _scalar_list(node):
    """A list of scalars, or of tiny objects (the `{"source": .., "locale": ..}` pairs of a search list)."""
    return isinstance(node, list) and all(isinstance(v, _SCALARS) or _tiny(v) for v in node)


def _tiny(node):
    """An object of at most three scalars, such as a citation's `{"kind": "record"}` binding."""
    return isinstance(node, dict) and len(node) <= 3 and all(isinstance(v, _SCALARS) for v in node.values())


def is_leaf(node):
    """A scalar, a list of scalars, or a flat object (scalar, scalar-list or tiny-object values)."""
    if isinstance(node, _SCALARS):
        return True
    if _scalar_list(node):
        return True
    return isinstance(node, dict) and all(isinstance(v, _SCALARS) or _scalar_list(v) or _tiny(v)
                                          for v in node.values())


def _inline(node):
    return json.dumps(node, ensure_ascii=False, separators=(", ", ": "))


def _render(node, level, indent):
    if is_leaf(node) or not node:
        return _inline(node)
    pad, close = " " * (indent * (level + 1)), " " * (indent * level)
    if isinstance(node, dict):
        body = ",\n".join(f"{pad}{json.dumps(k, ensure_ascii=False)}: {_render(v, level + 1, indent)}"
                          for k, v in node.items())
        return "{\n" + body + "\n" + close + "}"
    body = ",\n".join(f"{pad}{_render(v, level + 1, indent)}" for v in node)
    return "[\n" + body + "\n" + close + "]"


def dumps(doc, indent=1):
    """The document as compact JSON text, with its trailing newline."""
    return _render(doc, 0, indent) + "\n"
