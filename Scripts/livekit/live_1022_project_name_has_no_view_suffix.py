#!/usr/bin/env python3
"""Live proof that logic://project/info names the project and not the arrange view (#1022).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \\
        python3 live_1022_project_name_has_no_view_suffix.py <worktree> <full-40-char-head-sha> [binary]

`binary` defaults to `<worktree>/.build/release/LogicProMCP`. Pass a copy at a fresh path when the
build directory may be serving a stale image.

WHAT WAS WRONG
--------------
`AccessibilityChannel.defaultGetProjectInfo` assigned the arrange window's whole title to `name`.
Logic titles that window `<project> - <view>`, with the view in its own UI language: measured
2026-09-27 on Logic 12.3 with `lpm-locale-campaign` open, `name` read `lpm-locale-campaign - Tracks`
in English, `… - 트랙` in Korean, `… - トラック` in Japanese, `… - Spuren` in German, `… - Pistas` in
Spanish and Portuguese, `… - Pistes` in French, `… - Tracce` in Italian, `… - 轨道` in Simplified and
`… - 音軌` in Traditional Chinese. `ProjectReferenceIssuance` builds the `prj_` descriptor from that
name, so one project had a different descriptor in every language.

WHAT THIS MEASURES
------------------
One fresh server against the project Logic has open, in whichever language Logic is running:

    (a) `name` does not end with ` - ` followed by any spelling the product's own
        `AXLocalePolicy.arrangeWindowTitleSuffix` carries. The spellings are parsed out of the
        worktree's Swift source by `evidence.label_set`, not written here.
    (b) `name` is the project's bundle file name without `.logicx`, read from the `filePath` the
        SAME reply carries — when it carries one. A project that has never been saved has no path,
        and the product has no second source for it inside one server: `logic://project/audit`
        reports the cache the poller filled from the same project-file read, so asking it would
        compare the reply with itself. When the reply has no path this check is recorded as not
        run, and (c) is the independent reading.
    (c) The raw title of Logic's arrange window, read through System Events rather than through
        the product, is exactly `name` + ` - ` + one of those spellings. This is the reading that
        used to BE the name, taken from outside the server, so it cannot agree with a `name` that
        still carries the suffix and cannot agree with one that dropped anything but the suffix.

The counterexample every check is run against is the raw arrange-window title itself — the value
`name` held before this change — so a predicate that would have accepted the old reading fails here
in the same run.

WHAT THIS DOES NOT MEASURE
--------------------------
One language per run: the ten-language claim is ten runs of this harness with Logic relaunched in
each language, and each run's evidence names the suffix it saw. That the descriptor is the same
across languages is shown by the unit test over `ProjectReferenceIssuance.descriptor`; references
are minted per server and are not compared across runs here.

READ-ONLY
---------
Nothing here changes Logic: a cache refresh, resource reads, and System Events reading window names.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Project.swift",
    "Sources/LogicProMCP/State/ProjectReferenceIssuance.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = sys.argv[3] if len(sys.argv) > 3 else f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

# The product's own spellings, read from the worktree under test. A harness cannot link the product,
# and a list written here would be a second copy that drifts (Scripts/check-livekit-ui-literals.py).
SUFFIXES = E.label_set("arrangeWindowTitleSuffix", WT)
if not SUFFIXES:
    sys.exit("cannot run: AXLocalePolicy.arrangeWindowTitleSuffix was not found in the worktree")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

BUNDLE_EXTENSION = ".logicx"


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def arrange_window_titles():
    """The names of Logic's standard windows, one per line, read outside the product.

    Subrole AND name: Logic titles a plug-in editor by the TRACK name, which the user controls, so
    a title-only reading could hand back an AXDialog. The arrange window is an AXStandardWindow.
    One name per LINE rather than AppleScript's comma-joined list, because a project called
    `Take 1, final` would split into two windows that were never two windows.
    """
    rows = osa('set AppleScript\'s text item delimiters to linefeed\n'
               'tell application "System Events" to tell process "Logic Pro"\n'
               '  set out to {}\n'
               '  repeat with w in windows\n'
               '    set r to ""\n'
               '    try\n'
               '      set r to (subrole of w) as text\n'
               '    end try\n'
               '    set n to ""\n'
               '    try\n'
               '      set n to (name of w) as text\n'
               '    end try\n'
               '    set end of out to r & "\t" & n\n'
               '  end repeat\n'
               'end tell\n'
               'return out as text')
    titles = []
    for line in rows.splitlines():
        if "\t" not in line:
            continue
        subrole, _, name = line.partition("\t")
        if subrole.strip() == "AXStandardWindow":
            titles.append(name.strip())
    return titles


def carries_a_view_suffix(title, suffixes):
    return isinstance(title, str) and any(title.endswith(" - " + s) for s in suffixes)


# ---- One fresh server, one read ----------------------------------------------------------------
d = E.Driver()
time.sleep(5)
d.tool("logic_system", "refresh_cache")
info = d.resource("logic://project/info") or {}
# The body sits under the cache envelope's `data`.
info_data = info.get("data") if isinstance(info.get("data"), dict) else info
name = info_data.get("name")
file_path = info_data.get("filePath")
titles = arrange_window_titles()
# The reading `name` used to be: the arrange window's own title, taken from outside the server. If
# no standard window carries a known suffix the fallback is the shape the old code produced.
pre_change_name = next((t for t in titles if carries_a_view_suffix(t, SUFFIXES)), None) \
    or f"{name} - {SUFFIXES[0]}"
ev.note("1022/project-info", {
    "name": name, "filePath": file_path, "source": info.get("source"),
    "project_ref": info_data.get("project_ref"), "envelope_keys": sorted(info),
    "standard_window_titles": titles, "suffixes": SUFFIXES,
})

# The bundle's file name without the extension, when the reply carries a path. (a) needs it for a
# project whose own name ends in a view label, and (b) compares against it.
bundle_stem = None
if isinstance(file_path, str) and file_path.strip():
    bundle = os.path.basename(file_path.rstrip("/"))
    bundle_stem = bundle[:-len(BUNDLE_EXTENSION)] if bundle.endswith(BUNDLE_EXTENSION) else bundle

# (a) ------------------------------------------------------------------------------------------------
suffix_form = {"name": name, "suffixes": SUFFIXES, "bundle_stem": bundle_stem}
ev.falsifiable(
    "1022/name-carries-no-view-suffix",
    lambda o: (isinstance(o["name"], str) and bool(o["name"].strip())
               and (not carries_a_view_suffix(o["name"], o["suffixes"])
                    or o["name"] == o["bundle_stem"])),
    suffix_form,
    {**suffix_form, "name": pre_change_name},
    "logic://project/info's name is non-empty and does not end with ` - ` followed by any spelling "
    "of the arrange view the product knows, unless the project's own bundle name ends that way and "
    "the name is exactly that bundle name. THE COUNTEREXAMPLE is the arrange window's raw title, "
    "which is what name read before #1022",
    mutation="assign the window title to info.name unchanged in defaultGetProjectInfo "
             "(the pre-#1022 line)",
)

# (b) ------------------------------------------------------------------------------------------------
if bundle_stem is not None:
    bundle_form = {"name": name, "bundle_stem": bundle_stem, "filePath": file_path}
    ev.falsifiable(
        "1022/name-is-the-bundle-file-name",
        lambda o: bool(o["name"]) and o["name"] == o["bundle_stem"],
        bundle_form,
        {**bundle_form, "name": pre_change_name},
        "name equals the bundle file name of the same reply's filePath without its .logicx "
        "extension. THE COUNTEREXAMPLE is the raw window title in place of the name",
        mutation="strip the suffix in defaultGetProjectInfo but leave the separator, "
                 "`String(normalized.dropLast(label.count))`",
    )
else:
    ev.note("1022/name-is-the-bundle-file-name", {
        "not_run": "the reply carried no filePath, and the product has no second source for the "
                   "bundle path inside one server; (c) is the independent reading",
    })

# (c) ------------------------------------------------------------------------------------------------
title_form = {"name": name, "standard_window_titles": titles, "suffixes": SUFFIXES}
ev.falsifiable(
    "1022/the-arrange-window-title-is-the-name-plus-one-view-suffix",
    lambda o: (isinstance(o["name"], str) and bool(o["name"])
               and any(t == o["name"] + " - " + s
                       for t in o["standard_window_titles"] for s in o["suffixes"])),
    title_form,
    {**title_form, "name": pre_change_name},
    "one of Logic's standard windows, read through System Events, is titled exactly name + ` - ` + "
    "one known spelling of the arrange view: the title starts with the name and ends with the "
    "suffix, with nothing else between. THE COUNTEREXAMPLE is the raw title as the name, which "
    "would need a doubled suffix to match",
    mutation="drop every trailing ` - <label>` instead of exactly one, so a project named "
             "`Take 2 - Tracks` is reported as `Take 2`",
)

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
