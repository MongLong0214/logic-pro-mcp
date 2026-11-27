#!/usr/bin/env python3
"""Give every tracked file the modification time the cached build saw it with, when its content
is unchanged, and a time newer than anything in the cache when it is not.

Why this exists. `actions/checkout` stamps every file with the moment of checkout. SwiftPM
(llbuild, and swift-driver's incremental build record under it) decides what to recompile by
comparing each source's recorded modification time with the file on disk, so a restored `.build`
next to a fresh checkout looks entirely out of date and the whole 508-file test module is
compiled again.

What it does. `sync` reads the state written by the previous build (`path -> sha256, mtime`),
hashes every tracked file, and then sets
  - content equal to the recorded content: the recorded mtime, exactly, so the build database
    sees the file it already compiled;
  - anything else (changed, new, or no state at all): one common `stamp`, which is later than
    the current time and than every recorded mtime and every file under the build directory, so
    it differs from what the cache recorded and is newer than every product in it.
It then rewrites the state for the tree it just stamped. The decision is made on a SHA-256 of
the bytes, never on size or time, so a file whose content changed cannot be given the old mtime.
`swift build` stays the arbiter: this only removes the false "everything changed" signal.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

HEADER = "ci-source-state v1"
DEFAULT_STATE = ".build/ci-source-state.tsv"
SECOND = 1_000_000_000


def tracked_files(root):
    raw = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True,
                         stdout=subprocess.PIPE).stdout
    return sorted(os.fsdecode(item) for item in raw.split(b"\0") if item)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load_state(path):
    """The previous state, or {} when it is missing, unreadable or from another format."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        if lines[0] != HEADER:
            return {}
        state = {}
        for line in lines[1:]:
            if not line:
                continue
            sha, mtime_ns, quoted = line.split("\t", 2)
            state[json.loads(quoted)] = (sha, int(mtime_ns))
        return state
    except (OSError, ValueError):
        return {}


def newest_mtime_ns(directory):
    """The newest modification time of anything under `directory` (0 when it is absent)."""
    newest = 0
    stack = [directory]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            try:
                newest = max(newest, entry.stat(follow_symlinks=False).st_mtime_ns)
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
            except OSError:
                continue
    return newest


def sync(root, state_path, build_directory):
    previous = load_state(state_path)
    newest = max([mtime for _, mtime in previous.values()] +
                 [newest_mtime_ns(build_directory)] + [0])
    stamp = max(time.time_ns(), newest + SECOND)
    files = tracked_files(root)
    state, kept, changed = {}, 0, 0
    for name in files:
        path = os.path.join(root, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        sha = digest(path)
        recorded = previous.get(name)
        if recorded is not None and recorded[0] == sha:
            target, kept = recorded[1], kept + 1
        else:
            target, changed = stamp, changed + 1
        if os.stat(path).st_mtime_ns != target:
            os.utime(path, ns=(target, target))
        state[name] = (sha, target)
    removed = len(set(previous) - set(state))
    os.makedirs(os.path.dirname(os.path.abspath(state_path)), exist_ok=True)
    temporary = f"{state_path}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(HEADER + "\n")
        for name in sorted(state):
            sha, mtime = state[name]
            handle.write(f"{sha}\t{mtime}\t{json.dumps(name)}\n")
    os.replace(temporary, state_path)
    return {"tracked": len(state), "kept": kept, "changed": changed, "removed": removed,
            "had_state": bool(previous)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--state", default=DEFAULT_STATE)
    parser.add_argument("--build-directory", default=".build")
    args = parser.parse_args(argv)
    result = sync(args.root, args.state, args.build_directory)
    print("source mtimes: {tracked} tracked, {kept} kept at their recorded mtime, "
          "{changed} changed or new and stamped newer, {removed} gone since the cached build "
          "(previous state {state})".format(
              state="found" if result["had_state"] else "absent", **result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
