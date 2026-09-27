"""Own the live lane: one Logic, one driver.

Two things make a live run's readings belong to that run, and this module is both:

1. `LIVE.lock`, created with O_CREAT|O_EXCL so exactly one creator wins, holding the pid, host and
   purpose of whoever holds it. Default path `$S/LIVE.lock` (the coordinator's scratchpad); the
   environment variable `LPM_LIVE_LOCK` overrides it, which is how the tests point it elsewhere.
   A lock whose pid is dead on this host is STALE, and is reported as such. A lock that names no
   pid (`touch LIVE.lock`, which is how scratchpad/live291.sh takes it) cannot be proven stale and
   is treated as held.
2. No other LogicProMCP server and no `.xctest` bundle may be running. Either one opens virtual MCU
   ports of the same name and drives the real Logic (reference_suite_spawns_server_that_steals_
   mcu_ports: the release qualification suite drove Logic for ~350 s and left the marker list open).
   The process test is the one scratchpad/live291.sh:12 used, extended to the names binary.py gives
   its copies.

Every function returns raw observations. `claim()` is the context manager a live run uses: it waits
(bounded) for the lock to be absent, takes it, refuses when a competing process is up, and releases
in a `finally`.
"""

import contextlib
import json
import os
import re
import socket
import time

from . import obs

LOCK_ENV = "LPM_LIVE_LOCK"
DEFAULT_LOCK = ("/private/tmp/claude-501/-Users-isaac-projects-logic-pro-mcp/"
                "8632e9eb-402f-4b36-8b81-2d5c946339d3/scratchpad/LIVE.lock")

#: A server: the executable's basename starts with LogicProMCP (the build product, the copies
#: binary.py makes as LogicProMCP-<sha>-<sha256>, and live291.sh's -candidate/-control copies).
SERVER_EXECUTABLE = re.compile(r"^LogicProMCP(?:$|[-_.])")
#: A test bundle: the SwiftPM test product, run by xctest or swiftpm-testing-helper.
TEST_BUNDLE = re.compile(r"\.xctest\b|LogicProMCPPackageTests")


def lock_path():
    return os.environ.get(LOCK_ENV) or DEFAULT_LOCK


def pid_alive(pid):
    """True, False, or None when the question cannot be answered."""
    if not isinstance(pid, int) or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return None
    return True


def read_lock(path=None, alive=pid_alive):
    """What the lock file says, raw, and whether its holder is provably gone.

    `stale` is True only when the lock names a pid, on THIS host, that `alive` reports dead. A lock
    from another host, with no pid, or unparseable is never stale: it cannot be proven so.
    """
    path = path or lock_path()
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return {"path": path, "exists": False}
    except OSError as exc:
        return {"path": path, "exists": None, "cause": repr(exc)}
    text = raw.decode("utf-8", "replace")
    try:
        holder = json.loads(text) if text.strip() else None
    except ValueError:
        holder = None
    if not isinstance(holder, dict):
        holder = None
    pid = holder.get("pid") if holder else None
    host = holder.get("host") if holder else None
    same_host = host == socket.gethostname() if host is not None else None
    living = alive(pid) if isinstance(pid, int) and same_host else None
    return {"path": path, "exists": True, "raw": text, "holder": holder, "pid": pid, "host": host,
            "same_host": same_host, "pid_alive": living, "stale": living is False}


def _write_exclusive(path, body):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    try:
        os.write(fd, body)
    finally:
        os.close(fd)


def acquire(purpose, path=None, break_stale=True, alive=pid_alive):
    """Take the lock once, or say who has it. Never waits.

    A stale lock (see `read_lock`) is moved aside to `<path>.stale-<pid>-<ns>` and the exclusive
    create is tried once more; what was moved is returned. The move is a rename, so if two
    breakers race only one moves the file, and both then race on O_EXCL, which exactly one wins.
    """
    path = path or lock_path()
    token = f"{os.getpid()}-{time.time_ns()}"
    holder = {"pid": os.getpid(), "host": socket.gethostname(), "purpose": purpose,
              "token": token, "created_unix": time.time()}
    body = json.dumps(holder, sort_keys=True).encode("utf-8")
    broken = None
    for attempt in (0, 1):
        try:
            _write_exclusive(path, body)
            return {"acquired": True, "path": path, "holder": holder, "broke_stale": broken,
                    "attempts": attempt + 1}
        except FileExistsError:
            found = read_lock(path, alive=alive)
            if attempt == 0 and break_stale and found.get("stale"):
                aside = f"{path}.stale-{found.get('pid')}-{time.time_ns()}"
                try:
                    os.rename(path, aside)
                    broken = {"moved_to": aside, "was": found}
                except FileNotFoundError:
                    broken = {"moved_to": None, "was": found, "cause": "vanished before the move"}
                continue
            return {"acquired": False, "path": path, "found": found, "broke_stale": broken,
                    "attempts": attempt + 1}
        except OSError as exc:
            return {"acquired": False, "path": path, "cause": repr(exc), "attempts": attempt + 1}
    return {"acquired": False, "path": path, "broke_stale": broken, "attempts": 2}


def release(taken):
    """Remove the lock only if it is still the one `taken` wrote; say what was there."""
    path = taken.get("path")
    token = (taken.get("holder") or {}).get("token")
    if not taken.get("acquired") or not path:
        return {"released": False, "cause": "this handle never held the lock"}
    found = read_lock(path)
    if not found.get("exists"):
        return {"released": False, "cause": "the lock was already gone", "found": found}
    if (found.get("holder") or {}).get("token") != token:
        return {"released": False, "cause": "the lock now belongs to someone else", "found": found}
    try:
        os.unlink(path)
    except OSError as exc:
        return {"released": False, "cause": repr(exc), "found": found}
    return {"released": True, "path": path, "exists_after": os.path.exists(path)}


def wait_and_acquire(purpose, timeout_s, interval_s=5.0, path=None, alive=pid_alive):
    """Wait (bounded) for the lock to be absent or stale, then take it. Returns every poll."""
    path = path or lock_path()
    attempts = []

    def attempt():
        result = acquire(purpose, path=path, alive=alive)
        attempts.append({"t": obs.now(), **{k: v for k, v in result.items() if k != "holder"}})
        return result

    waited = obs.wait_until(attempt, timeout_s, interval_s, done=lambda r: r.get("acquired"))
    last = waited["last"]
    return {**last, "timed_out": waited["timed_out"], "waited_s": waited["elapsed_s"],
            "polls": waited["polls"], "attempts_log": attempts}


def process_table():
    """`ps` raw, bounded, twice: once for the executable path, once for the argument vector.

    Two calls because `comm` and `args` can both contain spaces (`Logic Pro`), so one line holding
    both cannot be split back apart. They are joined by pid.
    """
    return {"comm": obs.run(["/bin/ps", "-axww", "-o", "pid=,ppid=,comm="], 15),
            "args": obs.run(["/bin/ps", "-axww", "-o", "pid=,args="], 15)}


def parse_process_table(comm_text, args_text=""):
    args = {}
    for line in (args_text or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            args[int(parts[0])] = parts[1]
    rows = []
    for line in (comm_text or "").splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        pid = int(parts[0])
        rows.append({"pid": pid, "ppid": int(parts[1]), "comm": parts[2], "args": args.get(pid, "")})
    return rows


#: The runners that load a test bundle named in their arguments.
TEST_RUNNERS = ("xctest", "swiftpm-testing-helper")


def competing(rows, own_pids=()):
    """Servers and test bundles in a parsed process table, minus the pids this run started.

    A server is matched on the EXECUTABLE, never on arguments: a harness whose argv names a binary
    path is not a server. A test bundle is either an executable inside a `.xctest`, or a known
    runner whose arguments name one.
    """
    out = []
    for row in rows:
        if row["pid"] in own_pids:
            continue
        base = os.path.basename(row["comm"])
        if SERVER_EXECUTABLE.search(base):
            out.append({**row, "kind": "LogicProMCP server"})
        elif TEST_BUNDLE.search(row["comm"]) or (
                base in TEST_RUNNERS and TEST_BUNDLE.search(row.get("args") or "")):
            out.append({**row, "kind": "test bundle"})
    return out


def competing_now(own_pids=()):
    """The live answer: a raw process table and what in it competes for the MCU ports."""
    table = process_table()
    if table["comm"]["returncode"] != 0 or table["args"]["returncode"] != 0:
        return obs.unreadable("ps did not answer", ps=table)
    rows = parse_process_table(table["comm"]["stdout"], table["args"]["stdout"])
    if not rows:
        return obs.unreadable("ps answered with no parseable rows", ps=table)
    return obs.readable(competing(rows, own_pids), rows_seen=len(rows))


@contextlib.contextmanager
def claim(purpose, timeout_s, record, interval_s=5.0, path=None):
    """Hold the live lane for the body of a `with`; always release.

    `record` is a dict the caller keeps: `lock`, `competing` and `release` are written into it, so
    the evidence has them whether the body finished or raised. The body is entered only when the
    lock was taken AND no competing process was seen; otherwise `record["refused"]` says why and the
    body is not run (the manager yields False).
    """
    taken = wait_and_acquire(purpose, timeout_s, interval_s=interval_s, path=path)
    record["lock"] = taken
    try:
        if not taken.get("acquired"):
            record["refused"] = "the live lock was not acquired"
            yield False
            return
        rivals = competing_now()
        record["competing"] = rivals
        if not rivals["readable"]:
            record["refused"] = "the process table could not be read"
            yield False
            return
        if rivals["value"]:
            record["refused"] = "a LogicProMCP server or test bundle is running"
            yield False
            return
        yield True
    finally:
        if taken.get("acquired"):
            record["release"] = release(taken)
