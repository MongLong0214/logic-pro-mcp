#!/usr/bin/env python3
"""Drive `Scripts/check-factory-settings-folders.py` at each tree it must refuse, and at one it must pass.

Every case runs the guard's `main()` in a subprocess with `LPM_FACTORY_SETTINGS_REPO` aimed at a
temporary tree -- a catalog, a manifest and a pinned folder set written here -- because a case that
only called `problems()` would stay green under a `main()` that returned 0 unconditionally.

The first refusing case is the one #1030 is about: the Studio Piano seed removed while Apple still
ships its folder. The control beside it is the same tree with the seed in place.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "check-factory-settings-folders.py")
sys.path.insert(0, HERE)
import logic_canon as canon  # noqa: E402

SHIPPED = ["ES2", "Studio Piano", "Auto-Funk", "Sculpture"]

failures = []


def check(name, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} {name}")
    if not condition:
        failures.append(f"{name}: {detail}")


def catalog_text(seeds, exclusions, *, seeds_open="    private static let seeds: [Seed] = [\n"):
    seed_lines = "".join(f'        inst("{name.lower().replace(" ", "_")}", "{name}", "Synthesizer"),\n'
                         for name in seeds)
    exclusion_lines = "".join(f'        "{name}": stompbox("0007"),\n' for name in exclusions)
    return (
        "enum StockPluginCatalog {\n"
        "    static let factorySettingsFolderExclusions: [String: String] = [\n"
        f"{exclusion_lines}"
        "    ]\n\n"
        f"{seeds_open}"
        '        fx("channel_eq", "Channel EQ", "EQ"),\n'
        f"{seed_lines}"
        "    ]\n"
        "}\n"
    )


def write_tree(root, *, seeds, exclusions, shipped=SHIPPED, declared=None, with_source=True,
               catalog=None):
    plugins = os.path.join(root, "Sources", "LogicProMCP", "Plugins")
    absence = os.path.join(root, "docs", "canon", "absence")
    os.makedirs(plugins)
    os.makedirs(absence)
    with open(os.path.join(plugins, "StockPluginCatalog.swift"), "w", encoding="utf-8") as handle:
        handle.write(catalog if catalog is not None else catalog_text(seeds, exclusions))
    prefixes = sorted({canon._u32(canon.normalize(name)) for name in shipped})
    with open(os.path.join(absence, "pluginsettings.-.u32"), "wb") as handle:
        handle.write(b"LCA1" + struct.pack(">I", len(prefixes)))
        for prefix in prefixes:
            handle.write(struct.pack(">I", prefix))
    sources = {}
    if with_source:
        sources["pluginsettings"] = {"absence_entries": {"-": len(prefixes) if declared is None else declared},
                                     "locales": ["-"]}
    with open(os.path.join(root, "docs", "canon", "MANIFEST.json"), "w", encoding="utf-8") as handle:
        json.dump({"logic": {"version": "12.3", "build": "6674"}, "sources": sources}, handle)


def run(**tree):
    with tempfile.TemporaryDirectory() as root:
        write_tree(root, **tree)
        env = dict(os.environ, LPM_FACTORY_SETTINGS_REPO=root)
        result = subprocess.run([sys.executable, GUARD], env=env, capture_output=True, text=True)
        return result.returncode, result.stderr


def main() -> int:
    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk"])
    check("the control passes: every shipped folder is a seed or an exclusion", code == 0, err)

    code, err = run(seeds=["ES2", "Sculpture"], exclusions=["Auto-Funk"])
    check("the Studio Piano seed removed is refused", code == 1, err)
    check("and the refusal counts the one folder", "1 of the 4" in err, err)

    # Another exclusion stays, so the list is not empty and the refusal is about Auto-Funk.
    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["A Folder Nobody Ships"])
    check("an exclusion removed is refused", code == 1, err)
    check("and the refusal counts the one folder", "1 of the 4" in err, err)

    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk"],
                    shipped=SHIPPED + ["A Folder Apple Added"])
    check("a folder Apple added is refused", code == 1, err)

    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk", "ES2"])
    check("a name that is both a seed and an exclusion is refused", code == 1, err)
    check("and is named", "ES2" in err and "both a seed and an exclusion" in err, err)

    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk"], with_source=False)
    check("a manifest that pins no folder corpus is refused, not passed", code == 1, err)
    check("and says it cannot determine", "CANNOT DETERMINE" in err, err)

    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk"], declared=3)
    check("a folder set whose size disagrees with the manifest is refused", code == 1, err)

    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk"],
                    catalog=catalog_text(["ES2", "Studio Piano", "Sculpture"], ["Auto-Funk"],
                                         seeds_open="    private static let seedList: [Seed] = [\n"))
    check("a catalog whose seed list moved is refused, not read as empty", code == 1, err)
    check("and says it cannot determine", "CANNOT DETERMINE" in err, err)

    code, err = run(seeds=["ES2", "Studio Piano", "Sculpture"], exclusions=["Auto-Funk"], shipped=[])
    check("an empty folder set is refused", code == 1, err)

    if failures:
        print(f"\n{len(failures)} case(s) failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print("\ncheck-factory-settings-folders.py: every case behaved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
