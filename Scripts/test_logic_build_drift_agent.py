#!/usr/bin/env python3
"""The launchd trigger: what the agent writes, what it does on drift, and that it never starts while Logic is busy.

Nothing here touches launchd, Logic, git or Buzz: the agent takes its collaborators (lock, runner, poster) as
arguments, and `install(load=False)` only writes a file. Each guard is shown with a MUTANT: the source with the
line that enforces it neutralised, run through the same scenario, which must then go wrong.
"""
import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OBS = HERE / "observations"
SOURCE = OBS / "drift_agent.py"
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


def load(name, source=None):
    spec = importlib.util.spec_from_file_location(name, SOURCE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if source is None:
        spec.loader.exec_module(module)
    else:
        module.__file__ = str(SOURCE)
        exec(compile(source, str(SOURCE), "exec"), module.__dict__)
    return module


def mutated(old, new, name):
    text = SOURCE.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"mutant {name}: {old[:70]!r} occurs {text.count(old)} time(s), not once")
    return load(name, text.replace(old, new))


os.environ["LPM_LIVE_LOCK"] = str(Path(tempfile.mkdtemp()) / "lock")
agent = load("drift_agent_under_test")
live = agent.live_lock
DECLARED = {"version": "98.7", "build": "65432"}


class Spy:
    def __init__(self):
        self.ran, self.posted = [], []

    def runner(self, work, out):
        self.ran.append(work["branch"])
        return [f'RESULT: PASS {{"locale":"{l}"}}' for l in agent.LOCALES]

    def poster(self, argv, env):
        self.posted.append((argv, env))


# ---- the plist ---------------------------------------------------------------------------------------
doc = plistlib.loads(agent.plist_text("/repo", "/usr/bin/python3").encode("utf-8"))
case("the agent runs `--agent` hourly and when Logic's Info.plist changes",
     doc["ProgramArguments"][-1] == "--agent" and doc["StartInterval"] == 3600
     and doc["WatchPaths"] == ["/Applications/Logic Pro.app/Contents/Info.plist"], doc)
case("it does not start at load (a login must not drive Logic)", doc["RunAtLoad"] is False)
with tempfile.TemporaryDirectory() as tmp:
    target = Path(tmp) / "agent.plist"
    commands = agent.install("/repo", str(target), load=False)
    case("install writes the plist and names the launchctl bootstrap it would run",
         target.exists() and commands[1][:2] == ["launchctl", "bootstrap"] and str(target) in commands[1], commands)

# ---- no drift ----------------------------------------------------------------------------------------
spy, lines = Spy(), []
rc = agent.agent(DECLARED, ("98.7", "65432"), out=lines.append, runner=spy.runner, poster=spy.poster)
case("no drift: nothing runs and nothing is posted", rc == 0 and spy.ran == [] and spy.posted == [], lines)
rc = agent.agent(DECLARED, None, out=lines.append, runner=spy.runner, poster=spy.poster)
case("no Logic installed: nothing to compare, nothing runs", rc == 0 and spy.ran == [])

# ---- the dry run on a faked drift ---------------------------------------------------------------------
spy, lines = Spy(), []
rc = agent.agent(DECLARED, agent.parse_fake("13.1:7900"), dry_run=True, out=lines.append, runner=spy.runner,
                 poster=spy.poster)
text = "\n".join(lines)
case("a faked drift is detected and the dry run executes nothing", rc == 0 and spy.ran == [] and spy.posted == [], text)
case("it names a NEW branch, in its own worktree", "drift/logic-13.1-7900" in text and "worktree add -B" in text
     and "origin/main" in text, text)
case("it bumps the declaration, then re-ingests the canon, in that order",
     text.index("--bump 13.1 7900") < text.index("logic_canon.py build") < text.index("campaign:en-US"), text)
case("all ten locales are campaigned through the Aqua tmux gate",
     all(f"campaign:{l}" in text for l in agent.LOCALES) and text.count("tmux -L logic-aqua send-keys -t gate:0") == 10, text)
case("the live lock is handed down to each campaign", text.count("LPM_LIVE_LOCK_INHERITED=") == 10)
case("it uploads LFS objects before it pushes", text.index("git lfs push origin HEAD") < text.index("git push -u origin HEAD"))
case("the Buzz post is the documented one",
     "BUZZ_IDENTITY=cto-logic-pro-mcp buzz messages send --channel 6dcb2a67-b130-4c3c-8280-c32756a1c26a --content" in text, text)

# ---- a real run: lock, runner, post -------------------------------------------------------------------
spy, lines = Spy(), []
rc = agent.agent(DECLARED, ("13.1", "7900"), out=lines.append, runner=spy.runner, poster=spy.poster)
case("drift: the plan runs once and the RESULT lines are posted to the channel",
     rc == 0 and spy.ran == ["drift/logic-13.1-7900"] and len(spy.posted) == 1
     and spy.posted[0][0][4] == agent.BUZZ_CHANNEL and spy.posted[0][1] == {"BUZZ_IDENTITY": "cto-logic-pro-mcp"}
     and spy.posted[0][0][-1].count("RESULT: PASS") == 10, (rc, spy.ran, spy.posted[:1]))
case("the lock is released afterwards", live.holder() is None, live.holder())

holder = subprocess.Popen(["sleep", "30"])
try:
    assert live.acquire("another live run", pid=holder.pid)
    spy, lines = Spy(), []
    rc = agent.agent(DECLARED, ("13.1", "7900"), out=lines.append, runner=spy.runner, poster=spy.poster)
    case("another live run holds Logic: the agent defers (10), touches nothing, posts nothing",
         rc == 10 and spy.ran == [] and spy.posted == [] and "another live run" in "\n".join(lines), (rc, lines))
    rc = agent.agent(DECLARED, ("13.1", "7900"), dry_run=True, out=lines.append)
    case("even a dry run says the lock is held and that a real run would defer",
         rc == 10 and any("would defer" in l for l in lines), lines)
    m = mutated('    if not lock.acquire("logic-build-drift", wait=0):\n', "    if False:\n", "mut_agent_no_lock")
    spy = Spy()
    m.agent(DECLARED, ("13.1", "7900"), out=lambda _l: None, runner=spy.runner, poster=spy.poster, lock=live)
    case("MUTANT: without the lock check the agent drives Logic while another run holds it", spy.ran != [])
finally:
    live.release(pid=holder.pid)
    holder.kill()
    holder.wait()

m = mutated("    if tuple(installed_now) == target:\n", "    if False:\n", "mut_agent_no_drift_check")
spy = Spy()
m.agent(DECLARED, ("98.7", "65432"), out=lambda _l: None, runner=spy.runner, poster=spy.poster)
case("MUTANT: without the drift comparison it campaigns every hour", spy.ran != [])

# ---- the declaration bump ----------------------------------------------------------------------------
swift = 'enum P {\n    static let currentLogicVersion = "98.7"\n    static let currentLogicBuild = "65432"\n}\n'
bumped = agent.bump_declaration(swift, "13.1", "7900")
case("the bump sets both lines and nothing else",
     'currentLogicVersion = "13.1"' in bumped and 'currentLogicBuild = "7900"' in bumped and bumped.count("\n") == swift.count("\n"))
for broken in (swift.replace("    static let currentLogicBuild", "    static let other"), swift + swift):
    try:
        agent.bump_declaration(broken, "13.1", "7900")
        refused = False
    except ValueError:
        refused = True
    case("a declaration found zero or two times is refused", refused)
try:
    agent.parse_fake("13.1")
    refused = False
except ValueError:
    refused = True
case("--fake-installed wants VERSION:BUILD", refused)

# ---- the CLI ------------------------------------------------------------------------------------------
done = subprocess.run([sys.executable, str(HERE / "logic-build-drift.py"), "--agent", "--dry-run", "--fake-installed", "99.0:1"],
                      capture_output=True, text=True, env=dict(os.environ))
case("logic-build-drift.py --agent --dry-run --fake-installed shows the plan", done.returncode == 0
     and "DRIFT" in done.stdout and "drift/logic-99.0-1" in done.stdout, done.stdout[:300] + done.stderr[:300])
inherited = (OBS / "locale_campaign.py").read_text(encoding="utf-8")
case("a campaign accepts the lock its parent agent holds", "LPM_LIVE_LOCK_INHERITED" in inherited)

if failures:
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: the agent answers a drift on its own branch, never while Logic is busy")
