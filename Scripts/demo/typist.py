#!/usr/bin/env python3
"""Type plain-language requests into a live Claude Code session running in a tmux pane, one at a time.

  typist.py --target lpmdemo --log out/prompts.jsonl "request one" "@4.0 request two" ...
  typist.py --target lpmdemo --log out/prompts.jsonl --file requests.txt     (the re-record's musician-phrased list)

A request written "@N text" waits N seconds (instead of --gap) after the previous turn before it is typed, so a
part can be heard for a while before the next request.

Only the human side is automated: each request is typed character by character at a human pace (about 40 ms a
key, so it reads on screen) and submitted with Return. The script then waits until Claude Code is idle again (its
"esc to interrupt" busy line is gone for --settle seconds) before typing the next one. Claude decides on its own which
MCP tools to call and with what arguments; this script never sends a tool call. The log records when each request
started, when Return was pressed and when the turn went idle, on the same wall clock as the captures.
"""
import argparse
import json
import random
import re
import subprocess
import time

BUSY_MARKS = ("esc to interrupt", "esc to cancel")


def tmux(*args):
    return subprocess.run(["tmux", "-L", "logic-aqua", *args], capture_output=True, text=True, check=False)


def pane(target):
    return tmux("capture-pane", "-p", "-t", target).stdout


SPINNER = re.compile(r"\w…\s*\(\d+s")  # Claude Code's status line while a turn runs, e.g. "Pondering… (3s · ↓ 120 tokens)"


def busy(text):
    low = text.lower()
    return any(m in low for m in BUSY_MARKS) or bool(SPINNER.search(text))


def wait_idle(target, settle, timeout):
    t0 = time.time()
    idle_since = None
    saw_busy = False
    while time.time() - t0 < timeout:
        b = busy(pane(target))
        saw_busy = saw_busy or b
        now = time.time()
        if b:
            idle_since = None
        elif idle_since is None:
            idle_since = now
        if saw_busy and idle_since is not None and now - idle_since >= settle:
            return idle_since, True
        if not saw_busy and now - t0 > 8.0 and idle_since is not None and now - idle_since >= settle:
            return idle_since, False  # never saw a busy line: report it, do not guess
        time.sleep(0.1)
    return time.time(), False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--settle", type=float, default=1.2)
    ap.add_argument("--gap", type=float, default=0.6, help="pause between a turn going idle and the next request")
    ap.add_argument("--timeout", type=float, default=90.0)
    ap.add_argument("--key-ms", type=float, default=42.0)
    ap.add_argument("--file", help="read the requests from this file, one per line (# comments and blank lines are skipped)")
    ap.add_argument("prompts", nargs="*")
    a = ap.parse_args()
    if a.file:
        a.prompts = [l.strip() for l in open(a.file) if l.strip() and not l.lstrip().startswith("#")] + a.prompts
    if not a.prompts:
        ap.error("no requests: pass them as arguments or with --file")
    rng = random.Random(11)
    with open(a.log, "a", buffering=1) as log:
        for i, text in enumerate(a.prompts):
            gap = a.gap
            if text.startswith("@"):
                head, text = text.split(" ", 1)
                gap = float(head[1:])
            if i:
                time.sleep(gap)
            t_start = time.time()
            for ch in text:
                tmux("send-keys", "-t", a.target, "-l", ch)
                time.sleep(max(0.012, rng.gauss(a.key_ms, a.key_ms * 0.35)) / 1000.0)
            time.sleep(0.25)
            t_enter = time.time()
            tmux("send-keys", "-t", a.target, "Enter")
            t_idle, saw_busy = wait_idle(a.target, a.settle, a.timeout)
            rec = {"prompt": text, "t_start": t_start, "t_enter": t_enter, "t_idle": t_idle, "saw_busy": saw_busy}
            log.write(json.dumps(rec) + "\n")
            print(json.dumps(rec), flush=True)


if __name__ == "__main__":
    main()
