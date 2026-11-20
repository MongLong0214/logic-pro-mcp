#!/usr/bin/env python3
"""Pin the unattended campaign: its order, every refusal, and the RESULT line it ends on.

`Scripts/observations/locale-campaign.sh <locale>` is the one command per locale. Logic is not driven here:
`LPM_CAMPAIGN_PLAN` replaces a step's command with a stub that appends its name to a log, so what is pinned
is the engine's own behaviour -- which steps run in which order, that the first failure stops the run,
that nothing is committed before the checks pass or pushed before the preflight passes, that a lock held
by a live run is a HOLD that touches nothing, and that the LAST LINE is `RESULT: PASS|HOLD|FAIL {json}`.

Every guard is shown with a MUTANT: the engine's source with the line that enforces it neutralised, run
through the same scenario, which must then go wrong. A replacement that does not match exactly once fails
the suite.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OBS = HERE / "observations"
ENGINE = OBS / "locale_campaign.py"
WRAPPER = OBS / "locale-campaign.sh"
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


def load(path, name, source=None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if source is None:
        spec.loader.exec_module(module)
    else:
        module.__file__ = str(path)
        exec(compile(source, str(path), "exec"), module.__dict__)
    return module


def mutated(old, new, name):
    source = ENGINE.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"mutant {name}: {old[:70]!r} occurs {source.count(old)} time(s), not once")
    return load(ENGINE, name, source.replace(old, new))


engine = load(ENGINE, "campaign_engine")
STEPS = ("switch", "census", "prune", "canon", "rebind", "regenerate", "reclassify", "ratchet", "checks", "commit", "preflight", "lfs", "push")


def fixture(fail_at=None, holds=None, dirty=False):
    """A throwaway git repo plus a plan whose every step is a stub that logs its name."""
    root = Path(tempfile.mkdtemp())
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    (root / "docs/locale").mkdir(parents=True)
    (root / "docs/locale/holds.json").write_text(
        json.dumps({"holds": {"ko-KR": holds or {}}}), encoding="utf-8")
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "x"], cwd=root, check=True)
    if dirty:
        (root / "stray.txt").write_text("somebody else's work", encoding="utf-8")
    # Outside the repository: a campaign refuses a dirty tree, and the stubs' own files are not work.
    scratch = Path(tempfile.mkdtemp())
    log = scratch / "steps.log"
    plan = {}
    for step in STEPS:
        plan[step] = f"echo {step} >> {log}" + (" && false" if step == fail_at else "")
    plan["report"] = "echo 'ko-KR 48 12 0 0 194 1 1 207'"
    # The real precheck shells out to macOS's pgrep; procps pgrep on Linux prints an error for a name over
    # 15 characters, which the precheck reads as a live dialog source. The fixture must not depend on the
    # host OS, so it stubs the step (the dedicated pre-check cases below put it back, behind a fake pgrep).
    plan["precheck"] = "true"
    (scratch / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
    return root, log, plan


def run(module, root, plan, **kwargs):
    lines = []
    campaign = module.Campaign("ko-KR", repo=str(root), plan=plan, out=lines.append, **kwargs)
    result = campaign.run()
    return result, campaign.facts, lines, module.result_line(result, campaign.facts)


def logged(log):
    return log.read_text(encoding="utf-8").split() if log.exists() else []


def env_lock():
    os.environ["LPM_LIVE_LOCK"] = str(Path(tempfile.mkdtemp()) / "lock")
    live = load(OBS / "live_lock.py", "campaign_live_lock")
    return live


# ---- the happy path ---------------------------------------------------------------------------------
root, log, plan = fixture()
live = env_lock()
engine = load(ENGINE, "campaign_engine")
result, facts, lines, last = run(engine, root, plan)
case("a clean run is PASS", result == "PASS", (result, facts))
case("every step runs, in the documented order", logged(log) == list(STEPS), logged(log))
case("the RESULT line is `RESULT: PASS {json}` on one line",
     re.fullmatch(r"RESULT: PASS \{.*\}", last) and "\n" not in last, last)
payload = json.loads(last.split(" ", 2)[2])
case("the JSON names the locale, the result, the commit flag and the cells",
     payload["locale"] == "ko-KR" and payload["result"] == "PASS" and payload["pushed"] is True
     and payload["cells"]["current"] == 48, payload)
case("the lock is released after a run", live.holder() is None, live.holder())

# ---- the first failure stops the run, whichever step it is ------------------------------------------
for step in STEPS:
    root, log, plan = fixture(fail_at=step)
    result, facts, _lines, last = run(engine, root, plan)
    done = logged(log)
    case(f"a failing `{step}` is FAIL and names itself", result == "FAIL" and facts.get("failed_step") == step,
         (result, facts))
    case(f"nothing runs after a failing `{step}`", done == list(STEPS[:STEPS.index(step) + 1]), done)
    case(f"a failing `{step}` leaves the lock released", live.holder() is None)

root, log, plan = fixture(fail_at="checks")
run(engine, root, plan)
case("a failed check never reaches a commit or a push",
     "commit" not in logged(log) and "push" not in logged(log), logged(log))
root, log, plan = fixture(fail_at="preflight")
run(engine, root, plan)
case("a failed preflight is committed but never pushed", "commit" in logged(log) and "push" not in logged(log), logged(log))
case("a failed preflight uploads no LFS object either", "lfs" not in logged(log), logged(log))
root, log, plan = fixture(fail_at="lfs")
run(engine, root, plan)
case("a failed LFS upload stops before the push (a pointer without its object is a broken checkout)",
     "push" not in logged(log), logged(log))

m = mutated("        if code not in ok:\n            raise Refusal(name, f\"`{name}` exited {code}\")\n",
            "        pass\n", "mut_no_stop")
root, log, plan = fixture(fail_at="checks")
result, _f, _l, _last = run(m, root, plan)
case("MUTANT: ignoring a step's exit status commits after a failed check",
     "commit" in logged(log) and result != "FAIL", (result, logged(log)))

# ---- the lock ---------------------------------------------------------------------------------------
root, log, plan = fixture()
holder = subprocess.Popen(["sleep", "30"])
try:
    assert live.acquire("another campaign", pid=holder.pid)
    plan = {k: v for k, v in plan.items() if k != "lock"}
    result, facts, _l, last = run(engine, root, plan)
    case("a lock held by a live run is a HOLD that touches nothing", result == "HOLD" and logged(log) == [],
         (result, logged(log)))
    case("the HOLD names who holds Logic", "another campaign" in facts.get("reason", ""), facts)
    m = mutated('        if not live_lock.acquire(f"locale-campaign {self.locale}"):\n',
                '        if False:\n', "mut_no_lock")
    result, _f, _l, _last = run(m, root, plan)
    case("MUTANT: skipping the lock starts a run while another holds Logic", result != "HOLD" and logged(log) != [],
         (result, logged(log)))
finally:
    live.release(pid=holder.pid)
    holder.kill()
    holder.wait()
case("a lock whose owner is gone is taken over, not honoured forever",
     live.acquire("dead", pid=2 ** 22 + 12345) and live.acquire("next", wait=0), live.holder())
live.release()

# ---- a dirty tree -----------------------------------------------------------------------------------
root, log, plan = fixture(dirty=True)
plan = {k: v for k, v in plan.items() if k != "clean"}
result, facts, _l, _last = run(engine, root, plan)
case("a dirty tree is refused before anything runs", result == "FAIL" and facts.get("failed_step") == "clean"
     and logged(log) == [], (result, facts, logged(log)))
m = mutated('        if text.strip():\n            raise Refusal("clean"',
            '        if False:\n            raise Refusal("clean"', "mut_dirty_ok")
result, _f, _l, _last = run(m, root, plan)
case("MUTANT: skipping the clean check runs over somebody's uncommitted work",
     result != "FAIL" or logged(log) != [], (result, logged(log)))

# ---- the pre-check ----------------------------------------------------------------------------------
os.environ["LPM_CAMPAIGN_PRECHECK_WAIT"] = "0"
fake = Path(tempfile.mkdtemp())
for name, body in (("pgrep", 'echo "999 UserNotificationCenter"\nexit 0\n'),
                   ("pkill", "exit 0\n")):
    (fake / name).write_text("#!/bin/sh\n" + body, encoding="utf-8")
    (fake / name).chmod(0o755)
old_path = os.environ["PATH"]
os.environ["PATH"] = f"{fake}:{old_path}"
root, log, plan = fixture()
plan = {k: v for k, v in plan.items() if k != "precheck"}
result, facts, _l, _last = run(engine, root, plan)
os.environ["PATH"] = old_path
case("a system dialog source that survives the attempt to end it is FAIL", result == "FAIL"
     and facts.get("failed_step") == "precheck" and logged(log) == [], (result, facts))
m = mutated("            if not unc and not crawler:\n                return\n",
            "            return\n", "mut_precheck")
os.environ["PATH"] = f"{fake}:{old_path}"
result, _f, _l, _last = run(m, root, plan)
os.environ["PATH"] = old_path
case("MUTANT: a pre-check that always passes drives Logic past a system dialog",
     result != "FAIL" and logged(log) != [], (result, logged(log)))

# ---- HOLD versus PASS -------------------------------------------------------------------------------
root, log, plan = fixture(holds={"changed": {"a": {}}, "unconfirmed": {"b": {}, "c": {}}})
result, facts, _l, last = run(engine, root, plan)
case("held readings make a pushed, checked run a HOLD", result == "HOLD" and facts["pushed"] is True,
     (result, facts))
case("the HOLD line counts what was held",
     json.loads(last.split(" ", 2)[2])["holds"] == {"changed": 1, "unconfirmed": 2}, last)
m = mutated("        if held:\n            self.facts[\"reason\"]", "        if False:\n            self.facts[\"reason\"]", "mut_hold_is_pass")
result, _f, _l, _last = run(m, root, plan)
case("MUTANT: reporting PASS over held readings hides them", result == "PASS", result)

# ---- --no-push --------------------------------------------------------------------------------------
root, log, plan = fixture()
result, facts, _l, _last = run(engine, root, plan, push=False)
case("--no-push commits and never pushes", "push" not in logged(log) and "lfs" not in logged(log) and facts["pushed"] is False
     and "commit" in logged(log), (logged(log), facts))

# ---- a rebind happens exactly when a record was replaced ---------------------------------------------
root, log, plan = fixture()
rec = root / "docs/observations"
rec.mkdir(parents=True)
(rec / "2026-11-18-ko-KR-arrange-menus-census.json").write_text("{}", encoding="utf-8")
subprocess.run(["git", "add", "-A"], cwd=root, check=True)
subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "r"], cwd=root, check=True)
campaign = engine.Campaign("ko-KR", repo=str(root), plan={}, out=lambda _l: None)
case("an untouched record asks for no rebind", campaign.records_replaced() is False)
(rec / "2026-11-18-ko-KR-arrange-menus-census.json").write_text('{"a": 1}', encoding="utf-8")
case("a replaced record asks for --rebind", campaign.records_replaced() is True)
(rec / "2026-11-18-ko-KR-arrange-menus-census.json").write_text("{}", encoding="utf-8")
(rec / "2026-11-18-ko-KR-editor-event_list-census.json").write_text("{}", encoding="utf-8")
case("a record that is only NEW is not a replacement", campaign.records_replaced() is False)
(rec / "2026-11-18-de-DE-arrange-menus-census.json").write_text("{}", encoding="utf-8")
subprocess.run(["git", "add", "-A"], cwd=root, check=True)
subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "d"], cwd=root, check=True)
(rec / "2026-11-18-de-DE-arrange-menus-census.json").write_text('{"changed": true}', encoding="utf-8")
case("another locale's replaced record does not trigger this locale's rebind", campaign.records_replaced() is False)
m = mutated('        return any(line[:2].strip() == "M" for line in text.splitlines())',
            "        return True", "mut_always_rebind")
campaign_m = m.Campaign("ko-KR", repo=str(root), plan={}, out=lambda _l: None)
(rec / "2026-11-18-ko-KR-editor-event_list-census.json").unlink()
case("MUTANT: rebinding every run would re-bind digests nobody changed", campaign_m.records_replaced() is True
     and campaign.records_replaced() is False)

# ---- the commit says nothing it should not ----------------------------------------------------------
text = campaign.commit_command()
case("the commit carries no trailer", "Co-Authored" not in text and "Claude-Session" not in text
     and "--no-verify" not in text and "-n " not in text.replace("-m ", ""), text)
case("the commit stages only the campaign's own paths", all(p in text for p in engine.COMMIT_PATHS)
     and "git add -A --" in text, text)
case("the commit never disables a hook", "--no-verify" not in ENGINE.read_text(encoding="utf-8")
     and "core.hooksPath" not in ENGINE.read_text(encoding="utf-8"))

# ---- defect 2: a FAIL puts back what the run wrote, and only that -----------------------------------------
def writing_fixture(fail_at="checks", preexisting=False):
    root, log, plan = fixture(fail_at=fail_at)
    (root / "docs/observations").mkdir(parents=True, exist_ok=True)
    (root / "docs/observations/seed.json").write_text("{}", encoding="utf-8")
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "seed"], cwd=root, check=True)
    if preexisting:
        (root / "docs/locale/pre.txt").write_text("somebody else's, already there", encoding="utf-8")
        plan["clean"] = "true"
    plan["census"] = (f"echo census >> {log} && echo new > docs/observations/new.json && echo changed >> docs/locale/holds.json"
                      " && rm docs/observations/seed.json && echo outside > stray.txt")
    return root, log, plan


def porcelain(root):
    return subprocess.run(["git", "status", "--porcelain", "-uall"], cwd=root, capture_output=True, text=True).stdout.splitlines()


root, log, plan = writing_fixture()
result, facts, _l, last = run(engine, root, plan)
case("a FAIL restores tracked files, removes untracked ones it wrote and prints RESULT: FAIL",
     result == "FAIL" and last.startswith("RESULT: FAIL {") and porcelain(root) == ["?? stray.txt"], (result, porcelain(root)))
case("a FAIL says how many files it put back", facts.get("restored") == 3, facts)
case("a retry after a FAIL passes `clean`", not [x for x in porcelain(root) if "docs" in x])
root, log, plan = writing_fixture(fail_at="push")
run(engine, root, plan)
case("a FAIL after the commit leaves a clean tree too", porcelain(root) == ["?? stray.txt"], porcelain(root))
root, log, plan = writing_fixture(preexisting=True)
run(engine, root, plan)
case("a file that was dirty before the run is never touched",
     (root / "docs/locale/pre.txt").exists() and not (root / "docs/observations/new.json").exists(), porcelain(root))
m = mutated('            if refusal.result == "FAIL":\n                self.restore()\n', "            pass\n", "mut_no_restore")
root, log, plan = writing_fixture()
run(m, root, plan)
case("MUTANT: no restore leaves the run's files in the tree for the retry to trip on",
     (root / "docs/observations/new.json").exists(), porcelain(root))
m = mutated("            if path in self.baseline:\n                continue\n", "", "mut_restore_all")
root, log, plan = writing_fixture(preexisting=True)
run(m, root, plan)
case("MUTANT: restoring without the baseline destroys a file the run did not write",
     not (root / "docs/locale/pre.txt").exists(), porcelain(root))

# ---- defect 1: superseded evidence is pruned and re-pointed before the canon is built -----------------------
def dry_steps(module):
    lines = []
    module.Campaign("ja-JP", repo=str(root), plan={}, out=lines.append, dry_run=True, navigate=True).run()
    return [x for x in lines if x.startswith("== ")]


steps = dry_steps(engine)
names = [x.split(":")[0][3:] for x in steps]
case("the campaign prunes superseded evidence after the censuses and before the canon build",
     "prune" in names and names.index("navigate") < names.index("prune") < names.index("canon"), names)
case("the prune step is `census_pack.py prune --repoint` (records re-pointed, not left citing a deleted file)",
     any("census_pack.py prune --repoint" in x for x in steps), steps)
m = mutated('            self.step("prune", f"{py} Scripts/observations/census_pack.py prune --repoint")\n', "", "mut_no_prune")
case("MUTANT: a campaign without the prune step leaves two evidence files for one locale, kind and build",
     "prune" not in [x.split(":")[0][3:] for x in dry_steps(m)])

# ---- defect 3: a Swift literal the apply added is classified before the checks ---------------------------
# de-DE's apply added `Automation` and es-ES's `Reproducir` to the Swift; the campaign never re-ran the
# classification, so check-policy-literals-against-canon.py failed on a literal Logic ships.
reclassify = next((x for x in steps if x.startswith("== reclassify:")), "")
case("the campaign reclassifies the policy literals after the apply and before the ratchet and the checks",
     "reclassify" in names and names.index("regenerate") < names.index("reclassify") < names.index("ratchet")
     < names.index("checks"), names)
order = [reclassify.find(part) for part in ("check-policy-literals-against-canon.py --reclassify",
                                            "logic_canon.py build", "locale_labels.py --write")]
case("reclassify runs docs/canon/README.md's order: reclassify, build again, write",
     all(i >= 0 for i in order) and order == sorted(order), reclassify)
m = mutated('            self.step("reclassify", f"{py} Scripts/check-policy-literals-against-canon.py --reclassify && "\n'
            '                                    f"{py} Scripts/logic_canon.py build && {py} Scripts/locale_labels.py --write")\n',
            "", "mut_no_reclassify")
case("MUTANT: a campaign without the reclassify step reaches the checks with an unclassified literal",
     "reclassify" not in [x.split(":")[0][3:] for x in dry_steps(m)])

# ---- concurrency: every entry point that drives Logic refuses while another holds the lock -----------------
tools = Path(tempfile.mkdtemp())
for name, body in (("defaults", "exit 1\n"),):
    (tools / name).write_text("#!/bin/sh\n" + body, encoding="utf-8")
    (tools / name).chmod(0o755)
shadow = Path(tempfile.mkdtemp())
shutil.copytree(HERE, shadow / "Scripts", ignore=shutil.ignore_patterns("__pycache__"))
lockdir = str(Path(tempfile.mkdtemp()) / "lock")
os.environ["LPM_LIVE_LOCK"] = lockdir
other = subprocess.Popen(["sleep", "30"])
fixdir = tempfile.mkdtemp()
env = dict(os.environ, LPM_LIVE_LOCK=lockdir, LPM_LOCALE_FIXTURE=fixdir, PATH=f"{tools}:{os.environ['PATH']}")
env.pop("LPM_LIVE_LOCK_INHERITED", None)
try:
    assert live.acquire("a nav-census from another session", pid=other.pid)
    def tool(root_dir, *argv):
        done = subprocess.run(list(argv), cwd=root_dir, capture_output=True, text=True, env=env, timeout=60)
        return done.returncode, done.stdout + done.stderr
    def at(base, name):
        return str(base / "Scripts/observations" / name)
    rc, out = tool(HERE, sys.executable, at(HERE.parent, "nav-census.py"), "ja-JP", "--compare")
    case("nav-census.py refuses while another holds Logic", rc == 2 and "REFUSED" in out and "another live run" in out, (rc, out))
    rc, out = tool(HERE, sys.executable, at(HERE.parent, "label-census.py"), "run", "ja-JP")
    case("label-census.py run refuses while another holds Logic", rc == 2 and "REFUSED" in out and "another live run" in out, (rc, out))
    rc, out = tool(HERE, "/bin/bash", at(HERE.parent, "locale-switch.sh"), "ja-JP")
    case("locale-switch.sh refuses while another holds Logic", rc == 6 and "REFUSED" in out, (rc, out))
    # the campaign hands its lock down: a child of the holder is not refused
    env["LPM_LIVE_LOCK_INHERITED"] = str(other.pid)
    rc, out = tool(HERE, "/bin/bash", at(HERE.parent, "locale-switch.sh"), "ja-JP")
    case("a child of the lock's holder is let through (defaults stub ends it at exit 3)", rc == 3, (rc, out))
    env.pop("LPM_LIVE_LOCK_INHERITED")
    # mutants: the same entry points with their lock lines removed go on to do their work
    nav = (HERE.parent / "Scripts/observations/nav-census.py")
    src = nav.read_text(encoding="utf-8")
    old = 'ok, release = live_lock.take(f"nav-census {args.locale}")'
    assert src.count(old) == 1 and src.count("return _drive(args, plan)") == 1
    (shadow / "Scripts/observations/nav-census.py").write_text(
        src.replace(old, "ok, release = True, lambda: None").replace("return _drive(args, plan)", "return 99"), encoding="utf-8")
    rc, out = tool(shadow, sys.executable, at(shadow, "nav-census.py"), "ja-JP", "--compare")
    case("MUTANT: nav-census.py without the lock goes on to drive Logic", rc == 99, (rc, out))
    lab = HERE.parent / "Scripts/observations/label-census.py"
    src = lab.read_text(encoding="utf-8")
    old = 'ok, release = live_lock.take(f"label-census run {args.locale}")'
    assert src.count(old) == 1 and src.count("census = capture()") == 1
    (shadow / "Scripts/observations/label-census.py").write_text(
        src.replace(old, "ok, release = True, lambda: None").replace("census = capture()", "return 99"), encoding="utf-8")
    rc, out = tool(shadow, sys.executable, at(shadow, "label-census.py"), "run", "ja-JP")
    case("MUTANT: label-census.py run without the lock goes on to read Logic", rc == 99, (rc, out))
    sw = HERE.parent / "Scripts/observations/locale-switch.sh"
    src = sw.read_text(encoding="utf-8")
    old = 'python3 "$HERE/live_lock.py" acquire "locale-switch $LOCALE" >/dev/null ||'
    assert src.count(old) == 1
    (shadow / "Scripts/observations/locale-switch.sh").write_text(src.replace(old, "true ||"), encoding="utf-8")
    rc, out = tool(shadow, "/bin/bash", at(shadow, "locale-switch.sh"), "ja-JP")
    case("MUTANT: locale-switch.sh without the lock goes on to set the language (stub ends it at exit 3)", rc == 3, (rc, out))
    # the campaign itself refuses (HOLD) and hands the lock down when it takes it
    case("the campaign exports the lock to its children once it holds it",
         'os.environ["LPM_LIVE_LOCK_INHERITED"] = str(os.getpid())' in ENGINE.read_text(encoding="utf-8"))
finally:
    live.release(pid=other.pid)
    other.kill()
    other.wait()
    shutil.rmtree(shadow, ignore_errors=True)

# ---- the real script: the last line ------------------------------------------------------------------
def wrapper(args, env_extra):
    env = dict(os.environ, **env_extra)
    done = subprocess.run(["/bin/bash", str(WRAPPER), *args], capture_output=True, text=True, env=env, timeout=120)
    return done.returncode, done.stdout.strip().splitlines()


rc, out = wrapper(["nonsense-locale"], {})
case("a bad locale ends on a FAIL line", rc == 1 and out and out[-1].startswith("RESULT: FAIL {"), (rc, out))
root, log, plan = fixture()
plan_path = log.parent / "plan.json"
rc, out = wrapper(["ko-KR", "--no-push"],
                  {"LPM_CAMPAIGN_PLAN": str(plan_path), "LPM_CAMPAIGN_REPO": str(root),
                   "LPM_LIVE_LOCK": str(Path(tempfile.mkdtemp()) / "lock")})
case("the script's last line is the PASS line and it exits 0", rc == 0 and out[-1].startswith("RESULT: PASS {")
     and json.loads(out[-1].split(" ", 2)[2])["pushed"] is False, (rc, out[-2:]))
rc, out = wrapper(["ko-KR"], {"LPM_CAMPAIGN_PLAN": str(root / "does-not-exist.json"), "LPM_CAMPAIGN_REPO": str(root)})
case("an engine that crashes still ends on a FAIL line", rc == 1 and out[-1].startswith("RESULT: FAIL {")
     and json.loads(out[-1].split(" ", 2)[2])["result"] == "FAIL", (rc, out[-3:]))
sh_source = WRAPPER.read_text(encoding="utf-8")
broken = sh_source.replace('"RESULT: FAIL {"*"}") exit "$rc" ;;', '"RESULT: NEVER {"*"}") exit "$rc" ;;')
case("MUTANT premise: the wrapper's fallback line exists", broken != sh_source)
tmp_wrapper = Path(tempfile.mkdtemp()) / "locale-campaign.sh"
tmp_wrapper.write_text(sh_source.replace('HERE=$(cd "$(dirname "$0")" && pwd)', f'HERE="{OBS}"').replace(
    'python3 "$HERE/locale_campaign.py" "$@" 2>&1 | tee "$LOG"', 'echo "no result line at all" | tee "$LOG"'),
    encoding="utf-8")
done = subprocess.run(["/bin/bash", str(tmp_wrapper), "ko-KR"], capture_output=True, text=True)
case("a wrapper whose engine prints no RESULT line supplies a FAIL one",
     done.stdout.strip().splitlines()[-1].startswith("RESULT: FAIL {") and done.returncode == 1, done.stdout)

# ---- the runbook and the CI list agree with the checks the script runs ---------------------------------
ci = (HERE.parent / ".github/workflows/ci.yml").read_text(encoding="utf-8")
listed = subprocess.run(["/bin/bash", str(OBS / "locale-checks.sh"), "--list"], capture_output=True, text=True).stdout.split("\n")
for command in filter(None, listed):
    path = command.split("python3 ", 1)[1].split(" ")[0]
    case(f"CI also runs {path}", path in ci, command)
runbook = (HERE.parent / "docs/locale/CAMPAIGN-RUNBOOK.md")
case("the runbook exists and names the one command", runbook.exists()
     and "Scripts/observations/locale-campaign.sh" in runbook.read_text(encoding="utf-8"))

if failures:
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: the campaign runs in order, stops at the first failure, commits only after "
      f"its checks, pushes only after the preflight, and always ends on a RESULT line")
