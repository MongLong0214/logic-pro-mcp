#!/usr/bin/env python3
"""Every factory plug-in settings folder Logic ships is a catalog seed or a reasoned exclusion.

WHY THIS EXISTS
---------------
Issue #1030. `StockPluginCatalog` keys each seed by the name of its folder under Logic's factory
`Plug-In Settings` roots, and reads a plug-in's presets from that folder. Studio Piano's folder
ships only under `Plug-In Settings Internal`, no seed named it, and its presets were invisible with
nothing to say so. The Swift side now keeps one list, `factorySettingsFolderExclusions`, of every
folder no seed owns and why; this is the check that the seeds and that list still cover what Apple
ships, run where CI can run it -- against the folder names `Scripts/logic_canon.py build` pinned in
`docs/canon/absence/pluginsettings.-.u32`, with no Logic installed.

WHAT IT CHECKS
--------------
Every 32-bit digest prefix in that set is the prefix of a seed's display name or an exclusion's
key; the set is the size `MANIFEST.json` declares, and not empty; no name is both a seed and an
exclusion.

WHAT IT DOES NOT CLAIM
----------------------
- It cannot NAME a folder that is missing -- the canon pins digests, not names. It counts them,
  and says where to look on a machine with Logic.
- An unaccounted folder whose 32-bit prefix equals an accounted name's passes. The set holds 143
  prefixes, so the chance for one new folder is about 143 / 2**32.
- The shared `/Library/Application Support/Logic/Plug-In Settings` root is outside the bundle and
  outside the canon, so its folders are not checked here. `unaccountedFactorySettingsFolders(roots:)`
  checks all three roots on a machine that has them.
- It does not check that an exclusion still names a folder Apple ships.

Exit: 0 = every pinned folder is accounted for - 1 = one is not, or the inputs could not be read
"""
import json
import os
import re
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "Scripts"))
import logic_canon as canon  # noqa: E402

SOURCE, LOCALE = "pluginsettings", "-"


#: A seam, so the self-test can drive main() -- the entry point -- at a tree that must fail. One
#: ROOT, because the catalog, the manifest and the absence set must describe the same tree; pointing
#: one of them elsewhere would compare a fixture against the real repository.
def _root() -> str:
    return os.environ.get("LPM_FACTORY_SETTINGS_REPO") or REPO


def _paths(root: str) -> dict:
    return {
        "catalog": os.path.join(root, "Sources", "LogicProMCP", "Plugins", "StockPluginCatalog.swift"),
        "manifest": os.path.join(root, "docs", "canon", "MANIFEST.json"),
        "absence": os.path.join(root, "docs", "canon", "absence", f"{SOURCE}.{LOCALE}.u32"),
    }


SEEDS_OPEN = "private static let seeds: [Seed] = ["
EXCLUSIONS_OPEN = "static let factorySettingsFolderExclusions: [String: String] = ["
BLOCK_CLOSE = "\n    ]\n"
SEED_CALL = re.compile(r'\b(?:fx|inst|midiFX)\(\s*"[a-z0-9_]+",\s*"([^"]+)"')
EXCLUSION_KEY = re.compile(r'^\s*"([^"\n]+)":', re.M)


def _block(text: str, opener: str):
    start = text.find(opener)
    if start < 0:
        return None
    end = text.find(BLOCK_CLOSE, start)
    return None if end < 0 else text[start + len(opener):end]


def catalog_names(text: str):
    """(seed display names, exclusion keys), or a problem string when either list cannot be found."""
    seeds_block = _block(text, SEEDS_OPEN)
    exclusions_block = _block(text, EXCLUSIONS_OPEN)
    if seeds_block is None or exclusions_block is None:
        missing = [name for name, block in (("seeds", seeds_block), ("exclusions", exclusions_block))
                   if block is None]
        return None, None, (f"CANNOT DETERMINE: StockPluginCatalog.swift has no {' or '.join(missing)} "
                            f"list in the shape this reads. It moved; point this check at it, because a "
                            f"list it cannot find would account for nothing and fail everything, or "
                            f"account for everything if the reader were made lenient.")
    seeds = set(SEED_CALL.findall(seeds_block))
    exclusions = set(EXCLUSION_KEY.findall(exclusions_block))
    if not seeds or not exclusions:
        return None, None, ("CANNOT DETERMINE: read 0 seeds or 0 exclusions from StockPluginCatalog.swift. "
                            "Their shape changed, and an empty list here proves nothing.")
    return seeds, exclusions, None


def read_prefix_set(path: str) -> list:
    """The format `logic_canon.write_absence` writes: b"LCA1", a big-endian count, the prefixes."""
    with open(path, "rb") as handle:
        blob = handle.read()
    if blob[:4] != b"LCA1":
        raise canon.CanonError(f"{path}: not an absence set")
    count = struct.unpack_from(">I", blob, 4)[0]
    if len(blob) != 8 + 4 * count:
        raise canon.CanonError(f"{path}: declares {count} entries but holds {len(blob) - 8} bytes")
    return list(struct.unpack_from(f">{count}I", blob, 8))


def problems(root: str = None) -> list:
    paths = _paths(root or _root())
    try:
        with open(paths["catalog"], encoding="utf-8") as handle:
            seeds, exclusions, problem = catalog_names(handle.read())
    except OSError as exc:
        return [f"could not read the catalog: {exc}"]
    if problem:
        return [problem]

    out = []
    both = sorted(seeds & exclusions)
    if both:
        out.append(f"named as both a seed and an exclusion: {both}. A folder has one answer.")

    try:
        with open(paths["manifest"], encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as exc:
        return out + [f"could not read the canon manifest: {exc}"]
    block = (manifest.get("sources") or {}).get(SOURCE)
    if not isinstance(block, dict):
        return out + [f"CANNOT DETERMINE: docs/canon/MANIFEST.json pins no `{SOURCE}` corpus. Run "
                      f"`Scripts/logic_canon.py build --source {SOURCE}` on a machine with Logic; "
                      f"without it nothing says which folders Apple ships."]
    declared = (block.get("absence_entries") or {}).get(LOCALE)
    try:
        table = read_prefix_set(paths["absence"])
    except (OSError, canon.CanonError) as exc:
        return out + [f"could not read the pinned folder set: {exc}"]
    if not table:
        return out + ["the pinned folder set is empty; an empty set accounts for nothing and proves nothing"]
    if declared != len(table):
        return out + [f"the pinned folder set holds {len(table)} entries and MANIFEST.json declares "
                      f"{declared}. One of them was edited without the other."]

    accounted = {canon._u32(canon.normalize(name)) for name in seeds | exclusions}
    unaccounted = sorted(set(table) - accounted)
    if unaccounted:
        logic = manifest.get("logic") or {}
        out.append(
            f"{len(unaccounted)} of the {len(table)} factory plug-in settings folders Logic "
            f"{logic.get('version')} ({logic.get('build')}) ships in its bundle have neither a seed "
            f"nor an entry in `factorySettingsFolderExclusions`. The canon pins digests, not names: "
            f"on a machine with Logic, `StockPluginCatalog.unaccountedFactorySettingsFolders(roots:)` "
            f"names them, or list `Contents/Resources/Plug-In Settings` and "
            f"`Contents/Resources/Plug-In Settings Internal`. Give each a seed, or an exclusion that "
            f"says why it has none.")
    return out


def main() -> int:
    found = problems()
    for problem in found:
        print(f"factory settings folders: {problem}", file=sys.stderr)
    if found:
        return 1
    print("every factory plug-in settings folder the canon pins is a seed or a reasoned exclusion")
    return 0


if __name__ == "__main__":
    sys.exit(main())
