"""The observation shapes every module in this package returns, and its two bounded primitives.

A reading is one of two shapes, and nothing else:

    {"readable": True,  "value": <what was read>, ...raw detail}
    {"readable": False, "cause": "<why it could not be read>", ...raw detail}

A failure to observe is never folded into a value. `None`, `[]`, `False` and `""` are values; a read
that did not answer is `readable: False` with its cause (feedback_unreadable_is_not_absent: on one
day six sites answered "absent" for "could not read").

Every wait goes through `wait_until`, which is bounded and says whether it timed out. Every child
process goes through `run`, which is bounded, keeps its whole output and says whether it timed out.
There is no bare sleep used as synchronization anywhere in this package; the only sleep is the poll
interval inside `wait_until`.

Python 3.9 (/usr/bin/python3) and stdlib only.
"""

import subprocess
import time


def now():
    """The monotonic clock every record in this package is stamped with."""
    return time.monotonic()


def readable(value, **detail):
    return {"readable": True, "value": value, **detail}


def unreadable(cause, **detail):
    return {"readable": False, "cause": cause, **detail}


def wait_until(probe, timeout_s, interval_s=0.25, done=None):
    """Call `probe()` until `done(result)` holds or `timeout_s` passes.

    Returns every sample, not only the last one, so a reader can see what the wait saw:
    {"timed_out", "elapsed_s", "polls", "last", "samples": [{"t", "result"}]}. `done` defaults to
    truthiness. An exception from `probe` is recorded as a sample and the wait goes on; it is not a
    result.
    """
    done = done or bool
    started = now()
    samples = []
    while True:
        t = now()
        try:
            result = probe()
            ok = bool(done(result))
        except Exception as exc:  # noqa: BLE001 - a failed poll is a sample, not a verdict
            result, ok = {"probe_raised": repr(exc)}, False
        samples.append({"t": t, "result": result})
        if ok:
            return {"timed_out": False, "elapsed_s": now() - started, "polls": len(samples),
                    "last": result, "samples": samples}
        if now() - started >= timeout_s:
            return {"timed_out": True, "elapsed_s": now() - started, "polls": len(samples),
                    "last": result, "samples": samples}
        time.sleep(interval_s)


def run(argv, timeout_s, input_text=None, cwd=None, env=None):
    """Run one child process to completion or to its deadline, keeping everything it wrote."""
    started = now()
    try:
        proc = subprocess.run(argv, input=input_text, capture_output=True, text=True,
                              timeout=timeout_s, cwd=cwd, env=env)
        return {"argv": list(argv), "returncode": proc.returncode, "stdout": proc.stdout,
                "stderr": proc.stderr, "timed_out": False, "elapsed_s": now() - started}
    except subprocess.TimeoutExpired as exc:
        return {"argv": list(argv), "returncode": None,
                "stdout": _text(exc.stdout), "stderr": _text(exc.stderr),
                "timed_out": True, "elapsed_s": now() - started}
    except OSError as exc:
        return {"argv": list(argv), "returncode": None, "stdout": "", "stderr": repr(exc),
                "timed_out": False, "elapsed_s": now() - started, "spawn_error": repr(exc)}


def _text(raw):
    if raw is None:
        return ""
    return raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw


def osascript(script, timeout_s=20):
    """One AppleScript, bounded. The raw result is returned; `returncode` 0 is the only success."""
    return run(["/usr/bin/osascript", "-e", script], timeout_s)
