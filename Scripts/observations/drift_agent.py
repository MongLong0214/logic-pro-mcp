#!/usr/bin/env python3
"""The trigger: a launchd agent that notices a Logic update and answers it on its own branch.

`Scripts/logic-build-drift.py --install` writes and loads the agent; launchd then runs
`logic-build-drift.py --agent` every hour and whenever Logic's Info.plist changes. The agent compares the
installed Logic to the one `AXLocalePolicy.swift` declares. No drift: it says so and exits. Drift:

    1. it takes the live-run lock -- and never starts while another live run holds Logic (exit 10, HOLD;
       launchd tries again at the next interval and nothing was touched)
    2. it works on a NEW branch from origin/main, in its own worktree, never on a branch somebody is on
    3. it bumps the declaration, re-ingests the canon (`logic_canon.py build`) and commits both
    4. it runs `locale-campaign.sh <locale> --navigate --no-push` for all ten locales, each through the Aqua
       tmux gate (the one session Logic and its Accessibility grant live in), the lock handed down
    5. it uploads the LFS objects, pushes the branch, and posts every `RESULT:` line to Buzz

`--dry-run --fake-installed VERSION:BUILD` fakes the installed Logic and runs NOTHING: it prints each command
and the Buzz message, so the whole path is shown before a Logic update ever arrives.
"""
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import live_lock  # noqa: E402

AGENT_LABEL = "ai.lpm.logic-build-drift"
AGENT_PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{AGENT_LABEL}.plist")
LOGIC_PLIST = "/Applications/Logic Pro.app/Contents/Info.plist"
LOCALES = ("en-US", "ko-KR", "ja-JP", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR", "zh-CN", "zh-TW")
BUZZ_CHANNEL = "6dcb2a67-b130-4c3c-8280-c32756a1c26a"
BUZZ_IDENTITY = "cto-logic-pro-mcp"
GATE = ("tmux", "-L", "logic-aqua")
WORKTREES = os.path.expanduser("~/worktrees/logic-pro-mcp")
INTERVAL_SECONDS = 3600


def plist_text(repo=REPO, python=None):
    """The launchd agent: run `--agent` hourly and whenever Logic's Info.plist changes."""
    payload = {
        "Label": AGENT_LABEL,
        "ProgramArguments": [python or sys.executable, os.path.join(repo, "Scripts", "logic-build-drift.py"), "--agent"],
        "StartInterval": INTERVAL_SECONDS,
        "WatchPaths": [LOGIC_PLIST],
        "RunAtLoad": False,
        "WorkingDirectory": repo,
        "StandardOutPath": os.path.expanduser("~/Library/Logs/logic-build-drift.log"),
        "StandardErrorPath": os.path.expanduser("~/Library/Logs/logic-build-drift.log"),
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.path.expanduser("~/.local/bin")},
    }
    return plistlib.dumps(payload).decode("utf-8")


def install(repo=REPO, plist_path=AGENT_PLIST, load=True):
    """Write the plist and load it. Returns the launchctl commands (run, or only listed with load=False)."""
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    with open(plist_path, "w", encoding="utf-8") as handle:
        handle.write(plist_text(repo))
    domain = f"gui/{os.getuid()}"
    commands = [["launchctl", "bootout", f"{domain}/{AGENT_LABEL}"], ["launchctl", "bootstrap", domain, plist_path]]
    if load:
        subprocess.run(commands[0], capture_output=True)             # not loaded yet is fine
        done = subprocess.run(commands[1], capture_output=True, text=True)
        if done.returncode != 0:
            raise RuntimeError(f"launchctl bootstrap failed: {done.stderr.strip()}")
    return commands


def uninstall(plist_path=AGENT_PLIST):
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{AGENT_LABEL}"], capture_output=True)
    if os.path.exists(plist_path):
        os.remove(plist_path)


def parse_fake(text):
    """`13.1:7900` -> ("13.1", "7900")."""
    version, _sep, build = (text or "").partition(":")
    if not version or not build:
        raise ValueError(f"--fake-installed wants VERSION:BUILD, not {text!r}")
    return version, build


def bump_declaration(swift_text, version, build):
    """The policy source with the declared version and build set; ValueError unless each is found exactly once."""
    out = swift_text
    for name, value in (("currentLogicVersion", version), ("currentLogicBuild", build)):
        pattern = re.compile(r'(static let ' + name + r'\s*=\s*")[^"]*(")')
        found = len(pattern.findall(out))
        if found != 1:
            raise ValueError(f"AXLocalePolicy.swift declares `{name}` {found} times, not once")
        out = pattern.sub(lambda m: m.group(1) + value + m.group(2), out)
    return out


def branch_for(version, build):
    return f"drift/logic-{version}-{build}"


def gate_command(inner, tag, log_dir):
    """`inner` run in the Aqua tmux gate, and the command that waits for it."""
    log, exit_file, channel = os.path.join(log_dir, f"{tag}.log"), os.path.join(log_dir, f"{tag}.exit"), f"lpm-drift-{tag}"
    typed = (f"{inner} > {shlex.quote(log)} 2>&1; echo $? > {shlex.quote(exit_file)}; "
             f"{' '.join(GATE)} wait-for -S {channel}")
    send = " ".join(shlex.quote(a) for a in (*GATE, "send-keys", "-t", "gate:0", typed, "Enter"))
    return {"send": send, "wait": " ".join(shlex.quote(a) for a in (*GATE, "wait-for", channel)),
            "log": log, "exit": exit_file}


def plan(installed, repo=REPO, agent_pid=None):
    """Every step the agent runs for a drift to `installed` (version, build), in order, as data."""
    version, build = installed
    branch = branch_for(version, build)
    tree = os.path.join(WORKTREES, f"drift-{version}-{build}")
    log_dir = os.path.join(tree, ".drift-logs")
    q = shlex.quote
    # Navigation is part of a campaign once the navigation census exists in the tree being driven.
    navigate = " --navigate" if os.path.exists(os.path.join(repo, "Scripts", "observations", "nav-census.py")) else ""
    steps = [
        {"step": "fetch", "run": f"git -C {q(repo)} fetch origin main"},
        {"step": "worktree", "run": f"git -C {q(repo)} worktree add -B {q(branch)} {q(tree)} origin/main"},
        {"step": "bump", "cwd": tree,
         "run": f"python3 Scripts/logic-build-drift.py --bump {q(version)} {q(build)}"},
        {"step": "canon", "cwd": tree, "run": "python3 Scripts/logic_canon.py build"},
        {"step": "declare", "cwd": tree,
         "run": "git add -A && git commit -q -m " + q(f"feat(locale): declare Logic {version} ({build}) and re-ingest the canon")},
    ]
    for locale in LOCALES:
        steps.append({"step": f"campaign:{locale}", "locale": locale, "gate": gate_command(
            f"cd {q(tree)} && LPM_LIVE_LOCK_INHERITED={agent_pid or os.getpid()} Scripts/observations/locale-campaign.sh {locale} "
            f"{navigate.strip()} --no-push", f"campaign-{locale}", log_dir)})
    steps.append({"step": "push", "cwd": tree, "run": "git lfs push origin HEAD && git push -u origin HEAD"})
    return {"branch": branch, "worktree": tree, "steps": steps}


def buzz_command(text):
    """`(argv, env)` of the message post: `BUZZ_IDENTITY=... buzz messages send --channel <id> --content <text>`."""
    return ["buzz", "messages", "send", "--channel", BUZZ_CHANNEL, "--content", text], {"BUZZ_IDENTITY": BUZZ_IDENTITY}


def agent(declared, installed_now, dry_run=False, repo=REPO, out=print, runner=None, lock=live_lock, poster=None):
    """Detect drift and answer it. 0: nothing to do, or answered. 10: deferred because Logic is busy."""
    if declared is None or installed_now is None:
        out("agent: nothing to compare (no declaration, or no Logic installed)")
        return 0
    target = (str(declared["version"]), str(declared["build"]))
    if tuple(installed_now) == target:
        out(f"agent: no drift; declared and installed are Logic {target[0]} ({target[1]})")
        return 0
    out(f"agent: DRIFT declared {target[0]} ({target[1]}), installed {installed_now[0]} ({installed_now[1]})")
    work = plan(installed_now, repo)
    holder = lock.holder()
    busy = holder is not None and not holder.get("stale")
    if dry_run:
        out(f"agent: dry run, nothing is executed. Branch {work['branch']} in {work['worktree']}")
        for step in work["steps"]:
            if "gate" in step:
                out(f"  {step['step']}: {step['gate']['send']}")
                out(f"      then: {step['gate']['wait']}   (its RESULT line is the last line of {step['gate']['log']})")
            else:
                out(f"  {step['step']}: {step['run']}" + (f"   [in {step['cwd']}]" if step.get("cwd") else ""))
        out("  live lock: " + (f"HELD by {holder.get('owner')} -- a real run would defer (exit 10)" if busy else "free"))
        argv, env = buzz_command('Logic drift answered: one "RESULT: PASS|HOLD|FAIL {json}" line per locale')
        out("  buzz: " + " ".join(f"{k}={v}" for k, v in env.items()) + " " + " ".join(shlex.quote(a) for a in argv))
        return 10 if busy else 0
    if not lock.acquire("logic-build-drift", wait=0):
        held = lock.holder() or {}
        out(f"agent: HOLD -- another live run holds Logic ({held.get('owner')}, pid {held.get('pid')}); "
            f"nothing was touched, trying again at the next interval")
        return 10
    try:
        results = (runner or run_plan)(work, out)
    finally:
        lock.release(pid=os.getpid())
    argv, env = buzz_command(f"Logic {installed_now[0]} ({installed_now[1]}) drift on {work['branch']}:\n" + "\n".join(results))
    (poster or (lambda a, e: subprocess.run(a, env=dict(os.environ, **e))))(argv, env)
    return 0


def run_plan(work, out):
    """Execute the plan; return each campaign's RESULT line (a FAIL line stands in for one that left none)."""
    results = []
    for step in work["steps"]:
        out(f"agent: {step['step']}")
        if "gate" in step:
            gate = step["gate"]
            os.makedirs(os.path.dirname(gate["log"]), exist_ok=True)
            subprocess.run(gate["send"], shell=True)
            subprocess.run(gate["wait"], shell=True)
            try:
                with open(gate["log"], encoding="utf-8") as handle:
                    lines = handle.read().strip().splitlines()
            except OSError:
                lines = []
            results.append(lines[-1] if lines and lines[-1].startswith("RESULT: ") else
                           'RESULT: FAIL {"locale":"%s","reason":"the campaign left no RESULT line"}' % step["locale"])
            continue
        done = subprocess.run(step["run"], shell=True, cwd=step.get("cwd"), capture_output=True, text=True)
        if done.returncode != 0:
            results.append('RESULT: FAIL {"failed_step":"%s","reason":%s}' % (step["step"], json.dumps(done.stderr.strip()[:300])))
            if step["step"] in ("fetch", "worktree", "bump", "canon", "declare"):
                break
    return results
