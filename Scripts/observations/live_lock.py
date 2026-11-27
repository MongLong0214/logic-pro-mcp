#!/usr/bin/env python3
"""One live run at a time: the lock every job that drives Logic holds while it does.

Logic is one process with one language and one open project. A campaign that switches it to Japanese
while another job reads the Korean menu bar does not fail loudly; it reads the wrong language and files
it as a measurement. So whoever is about to touch Logic takes this lock first, and whoever finds it held
does not start -- it reports who holds it and exits.

    live_lock.py acquire OWNER [--wait SECONDS]   exit 0 and print the lock path; exit 1 if held
    live_lock.py release                          release a lock this process tree owns (pid in file)
    live_lock.py holder                           print the holder as JSON, or `free`; exit 0 if free

The lock is a directory (`mkdir` is atomic) holding `owner.json` with the pid and a start time. A lock
whose pid is gone is STALE and is taken over, because a crashed run must not strand Logic for good; a
lock whose pid is alive is never broken, however old.
"""
import json
import os
import sys
import tempfile
import time

def lock_path():
    """Where the lock lives, read at CALL time so a test (or a second job) can point it elsewhere."""
    return os.environ.get("LPM_LIVE_LOCK") or os.path.join(tempfile.gettempdir(), "lpm-logic-live.lock")


LOCK = lock_path()


def _alive(pid):
    try:
        os.kill(int(pid), 0)
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        return True
    return True


def holder(path=None):
    """The lock's holder as a dict, or None when the lock is free or stale."""
    path = path or lock_path()
    try:
        with open(os.path.join(path, "owner.json"), encoding="utf-8") as handle:
            info = json.load(handle)
    except (OSError, ValueError):
        # A lock directory with no readable owner is one a crashed acquirer left half-made.
        return {"owner": "unknown", "pid": None, "stale": True} if os.path.isdir(path) else None
    info["stale"] = not _alive(info.get("pid"))
    return info


def acquire(owner, pid=None, path=None, wait=0):
    """True when the lock is now held by `owner` (process `pid`), False when someone alive holds it."""
    path = path or lock_path()
    pid = pid or os.getpid()
    deadline = time.time() + wait
    while True:
        try:
            os.mkdir(path)
        except FileExistsError:
            info = holder(path)
            if info is not None and not info.get("stale"):
                if time.time() >= deadline:
                    return False
                time.sleep(2)
                continue
            # Stale: its owner is gone. Take over -- but through a rename so two takers cannot both win.
            try:
                os.rename(path, f"{path}.stale.{os.getpid()}")
            except OSError:
                continue
            _discard(f"{path}.stale.{os.getpid()}")
            continue
        with open(os.path.join(path, "owner.json"), "w", encoding="utf-8") as handle:
            json.dump({"owner": owner, "pid": pid, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, handle)
        return True


def _discard(path):
    try:
        for name in os.listdir(path):
            os.unlink(os.path.join(path, name))
        os.rmdir(path)
    except OSError:
        pass


def release(pid=None, path=None):
    """Release the lock if `pid` holds it. Returns True when it was released."""
    path = path or lock_path()
    info = holder(path)
    if info is None or (pid is not None and info.get("pid") != pid):
        return False
    _discard(path)
    return True


def inherited(path=None):
    """True when a live holder started this process and handed the lock down (`LPM_LIVE_LOCK_INHERITED`)."""
    value = os.environ.get("LPM_LIVE_LOCK_INHERITED", "")
    info = holder(path)
    return bool(value.isdigit() and info and not info.get("stale") and info.get("pid") == int(value))


def take(owner):
    """The guard every entry point that drives Logic calls first.

    Returns `(True, release)` when this process may drive Logic (it took the lock, or the campaign that
    started it already holds it), `(False, message)` when somebody else alive holds it. `release()` is
    always safe to call, once, when the work is done.
    """
    if inherited():
        return True, lambda: None
    if acquire(owner, pid=os.getpid()):
        return True, lambda: release(pid=os.getpid())
    held = holder() or {}
    return False, f"another live run holds Logic ({held.get('owner')}, pid {held.get('pid')}); nothing was touched"


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "holder":
        info = holder()
        if info is None or info.get("stale"):
            print("free")
            return 0
        print(json.dumps(info))
        return 1
    if cmd == "acquire":
        wait = int(argv[argv.index("--wait") + 1]) if "--wait" in argv else 0
        # The PARENT's pid: this process exits at once, and a lock held by a dead pid is stale by rule.
        owner_pid = os.getppid()
        if inherited():
            print(lock_path())
            return 0
        if acquire(argv[1] if len(argv) > 1 else "unknown", pid=owner_pid, wait=wait):
            print(lock_path())
            return 0
        print(json.dumps(holder()))
        return 1
    if cmd == "release":
        return 0 if release(pid=os.getppid()) else 1
    print(f"unknown command {cmd!r}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
