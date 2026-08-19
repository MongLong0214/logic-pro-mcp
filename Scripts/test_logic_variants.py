#!/usr/bin/env python3
"""Drive `logic_variants` and assert what comes back.

`Scripts/check-python-contracts.py` proves every name a consumer references exists and every call
binds. It cannot see a function that keeps its name and signature and starts returning something
else — nothing static can, in untyped Python. This is that half, for this module.

Measured before it was written: all ten consumed functions drive with no Logic and no display.
`resolve_bundle_id` takes `is_running` / `is_installed` as callables, so the whole decision is
exercisable with injected answers rather than a running application — that is a property of how the
module was written, not something assumed from `evidence.py` being drivable.

    python3 test_logic_variants.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logic_variants as V  # noqa: E402

DESKTOP = "com.apple.logic10"
CREATOR = "com.apple.mobilelogic"

failed = 0
checks = []


def shape(why, ok):
    checks.append((why, bool(ok)))


variants = V.manifest_variants()
shape("manifest_variants returns a tuple", isinstance(variants, tuple))
shape("each variant is a mapping with name and bundle_id",
      all(isinstance(v, dict) and {"name", "bundle_id"} <= set(v) for v in variants))

for name, value, kind in [
    ("manifest_bundle_ids_in_order", V.manifest_bundle_ids_in_order(), tuple),
    ("bundle_ids_in_priority_order", V.bundle_ids_in_priority_order(), tuple),
    ("process_names_in_priority_order", V.process_names_in_priority_order(), tuple),
    ("logic_app_names", V.logic_app_names(), frozenset),
    ("known_bundle_ids", V.known_bundle_ids(), frozenset),
]:
    shape(f"{name} returns {kind.__name__}", isinstance(value, kind))
    shape(f"{name} holds only strings", all(isinstance(x, str) for x in value))

shape("desktop sorts before creator in priority order",
      list(V.bundle_ids_in_priority_order()).index(DESKTOP)
      < list(V.bundle_ids_in_priority_order()).index(CREATOR))
shape("process_name_for_bundle_id returns a str", isinstance(V.process_name_for_bundle_id(DESKTOP), str))
shape("jxa_find_process_snippet returns a str", isinstance(V.jxa_find_process_snippet(), str))
shape("is_logic_frontmost_app returns a bool", isinstance(V.is_logic_frontmost_app("Logic Pro"), bool))
shape("is_logic_frontmost_app(None) is False", V.is_logic_frontmost_app(None) is False)

# The decision itself, with injected answers. No Logic, no display, no filesystem.
running_desktop = V.resolve_bundle_id(
    forced_bundle_id=None, frontmost_bundle_id=None,
    is_running=lambda b: b == DESKTOP, is_installed=lambda b: True)
shape("resolve_bundle_id returns a str", isinstance(running_desktop, str))
shape("a running desktop resolves to desktop", running_desktop == DESKTOP)

forced = V.resolve_bundle_id(
    forced_bundle_id=CREATOR, frontmost_bundle_id=None,
    is_running=lambda b: False, is_installed=lambda b: True)
shape("an explicit force is honoured", forced == CREATOR)

# NOT asserted here, and worth saying: that forcing CREATOR is ALLOWED is the runtime half of the
# ship-scope gap — the matrix qualifies desktop only, and this function will still return the
# unqualified variant when asked. Changing that is a behaviour change on a setup path and belongs
# in its own change with its own evidence. This drive pins the CONTRACT as it stands.

for why, ok in checks:
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {why}")
print(f"\n{'FAILED' if failed else 'all shapes held'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
