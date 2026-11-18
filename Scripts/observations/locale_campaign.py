#!/usr/bin/env python3
"""One locale, end to end, unattended: the engine behind `Scripts/observations/locale-campaign.sh`.

    locale_campaign.py <locale> [--dry-run] [--no-push] [--branch NAME] [--navigate]
    locale_campaign.py <locale> --from-evidence CENSUS.json     re-file a census already taken: no Logic is
                                                                driven, so no lock and no language switch

Every step a person used to run by hand, in the order that is safe, and a refusal at every point where
going on would write something false:

    precheck     no system dialog source (UserNotificationCenter) and no filesystem crawler running; one
                 attempt to end the former, never a click
    clean        the working tree is clean: a campaign commits its own files and nobody else's
    lock         the live-run lock (live_lock.py): never start while another run holds Logic
    switch       locale-switch.sh: set the language, quit WITHOUT saving, relaunch on the fixture
    census       label-census.py run --write --confirm: read the menu bar and main window, prove the
                 locale, confirm unplaced strings against the installed Logic, file the records
    navigate     (--navigate) nav-census.py: open each surface the plan names, read it, put it back
    prune        census_pack.py prune --repoint: evidence a newer file of the same locale, kind and build
                 supersedes is deleted, and the readings citing its records are re-pointed (rule R2)
    canon        logic_canon.py build: pin the citations the new records carry
    rebind       locale_labels.py --write [--rebind]: --rebind exactly when a record was REPLACED
    regenerate   locale-regenerate.py --apply --rule-only, until it writes nothing: take a reading only
                 where it equals the label's own canon value; hold and record the rest
    ratchet      check-observation-ratchets.py --rebaseline: allowed sets follow what is now measured
    checks       locale-checks.sh: every canon-locales check; any failure ends the run before a commit
    commit       one commit of the files the run wrote, no trailers, hooks on
    preflight    the public-surface preflight must PASS before a push
    lfs          git lfs push: raw census evidence is stored in Git LFS and the repository's pre-push hook
                 does not upload it, so the objects go first; a pointer pushed without its object is a
                 checkout that cannot read its own evidence
    push

On any FAIL after `clean` passed, every tracked file the run changed is restored and every untracked file it
wrote is removed (only under COMMIT_PATHS, and only what was not already dirty when the run began, which
`clean` makes nothing), so the tree ends clean and the same command can simply be run again.

The last line printed is always `RESULT: PASS|HOLD|FAIL {json}`:

    PASS  every step ran, every check passed, the work is pushed, and nothing is held
    HOLD  the work is committed and pushed and every check passed, but some readings were held (a changed
          string that is not the label's canon value, a candidate the canon does not vouch for, a
          reading the census did not reach), OR the run did not start because another live run holds
          Logic (nothing was touched)
    FAIL  a step failed; nothing after it ran, and nothing was pushed unless the step is `push`'s own

Tests drive every guard through `LPM_CAMPAIGN_PLAN`, a JSON object mapping a step name to the shell
command that replaces it, so the ordering, the stop-on-failure and the RESULT line are pinned without
Logic. Unset, the steps below run as written.
"""
import json
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import live_lock  # noqa: E402

PREFLIGHT = os.environ.get("LPM_PREFLIGHT") or os.path.expanduser("~/.claude/scripts/lpm-public-surface-preflight.sh")
STEP_ORDER = ("precheck", "clean", "lock", "switch", "census", "navigate", "prune", "canon", "rebind", "regenerate",
              "ratchet", "checks", "commit", "preflight", "lfs", "push")
LOCALES = ("en-US", "ko-KR", "ja-JP", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR", "zh-CN", "zh-TW")
#: Files a campaign writes and commits. Nothing else is staged: a campaign must not carry along whatever
#: else was lying in the tree.
COMMIT_PATHS = ("docs", "Scripts/logic_ui_labels.py", "Sources/LogicProMCP/Accessibility")


class Refusal(Exception):
    """A step refused. `result` is FAIL unless the refusal is the 'Logic is busy elsewhere' HOLD."""

    def __init__(self, step, reason, result="FAIL"):
        super().__init__(reason)
        self.step, self.reason, self.result = step, reason, result


def sh(command, repo, check_name=None, capture=False):
    """Run a shell command in `repo`; return (exit code, combined output)."""
    done = subprocess.run(command, shell=True, cwd=repo, executable="/bin/bash",
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None, text=True)
    return done.returncode, (done.stdout or "") if capture else ""


class Campaign:
    def __init__(self, locale, repo=REPO, plan=None, dry_run=False, push=True, branch=None, navigate=False,
                 out=print, evidence=None):
        self.locale, self.repo, self.dry_run, self.push, self.branch = locale, repo, dry_run, push, branch
        self.navigate = navigate
        self.evidence = evidence
        self.plan = plan if plan is not None else _plan_from_env()
        self.out = out
        self.facts = {"locale": locale}
        self.locked = False
        self.baseline = None

    # -- plumbing ---------------------------------------------------------------------------------
    def step(self, name, default_command, ok=(0,)):
        """Run step `name`: the plan's command if the plan names one, else `default_command`."""
        command = self.plan.get(name, default_command)
        self.out(f"== {name}: {command if isinstance(command, str) else '(built in)'}")
        if self.dry_run:
            return ""
        if command is None:
            return ""
        code, text = sh(command, self.repo, capture=True)
        if text:
            self.out(text.rstrip())
        if code not in ok:
            raise Refusal(name, f"`{name}` exited {code}")
        return text

    # -- steps ------------------------------------------------------------------------------------
    def precheck(self):
        if "precheck" in self.plan:
            self.step("precheck", None)
            return
        self.out("== precheck: no UserNotificationCenter, no filesystem crawler")
        if self.dry_run:
            return
        for attempt in range(3):
            unc = sh("pgrep -x UserNotificationCenter", self.repo, capture=True)[1].strip()
            crawler = sh("pgrep -fl '^bfs |^find /'", self.repo, capture=True)[1].strip()
            if not unc and not crawler:
                return
            if unc:
                sh("pkill -TERM -x UserNotificationCenter", self.repo, capture=True)
            sh(f"sleep {os.environ.get('LPM_CAMPAIGN_PRECHECK_WAIT', '3')}", self.repo, capture=True)
        raise Refusal("precheck", f"a system dialog source or a filesystem crawler is still running "
                                  f"(UserNotificationCenter={bool(unc)}, crawler={bool(crawler)})")

    def clean(self):
        text = self.step("clean", "git status --porcelain")
        if "clean" in self.plan:
            return
        if text.strip():
            raise Refusal("clean", "the working tree is not clean; a campaign commits only its own files")

    def lock(self):
        if "lock" in self.plan:
            self.step("lock", None)
            self.locked = True
            return
        self.out("== lock: the live-run lock")
        if self.dry_run:
            return
        inherited = os.environ.get("LPM_LIVE_LOCK_INHERITED", "")
        holder = live_lock.holder()
        if inherited.isdigit() and holder and holder.get("pid") == int(inherited) and not holder.get("stale"):
            # The drift agent holds the lock for its whole run and hands it down; this run neither takes
            # nor releases it. A lock held by anybody else is still a HOLD.
            self.out(f"   held by {holder.get('owner')} (pid {inherited}), which started this run")
            return
        if not live_lock.acquire(f"locale-campaign {self.locale}"):
            held = live_lock.holder() or {}
            raise Refusal("lock", f"another live run holds Logic ({held.get('owner')}, pid {held.get('pid')}); "
                                  f"nothing was touched", result="HOLD")
        self.locked = True
        # Every child that drives Logic (switch, census, navigate) sees the lock as handed down.
        os.environ["LPM_LIVE_LOCK_INHERITED"] = str(os.getpid())

    def unlock(self):
        if self.locked and "lock" not in self.plan:
            live_lock.release(pid=os.getpid())
            os.environ.pop("LPM_LIVE_LOCK_INHERITED", None)
        self.locked = False

    def dirty(self):
        """{path: porcelain status} of every changed or untracked file under COMMIT_PATHS."""
        _code, text = sh("git status --porcelain -uall -- " + " ".join(shlex.quote(p) for p in COMMIT_PATHS),
                         self.repo, capture=True)
        return {line[3:].strip('"'): line[:2] for line in text.splitlines() if line.strip()}

    def restore(self):
        """Undo what this run wrote: tracked files back to HEAD, untracked ones removed. Never touches a
        file that was already dirty before the run (`self.baseline`), so nobody else's work is lost."""
        if self.baseline is None or self.dry_run:
            return
        removed = []
        for path, status in sorted(self.dirty().items()):
            if path in self.baseline:
                continue
            if status == "??" or status[0] == "A":
                sh(f"git rm -q -f --cached --ignore-unmatch -- {shlex.quote(path)}", self.repo, capture=True)
                try:
                    os.remove(os.path.join(self.repo, path))
                except OSError:
                    pass
            else:
                sh(f"git restore --staged --worktree --source=HEAD -- {shlex.quote(path)}", self.repo, capture=True)
            removed.append(path)
        if removed:
            self.out(f"== restore: {len(removed)} file(s) this run wrote were put back")
        self.facts["restored"] = len(removed)

    def records_replaced(self):
        """Whether the census replaced an observation record that already existed (a rebind is then due)."""
        code, text = sh(f"git status --porcelain -- 'docs/observations/*-{self.locale}-*-census.json'",
                        self.repo, capture=True)
        return any(line[:2].strip() == "M" for line in text.splitlines())

    # -- the run ----------------------------------------------------------------------------------
    def run(self):
        py = shlex.quote(sys.executable)
        loc = shlex.quote(self.locale)
        try:
            self.clean()
            self.baseline = set() if self.dry_run else set(self.dirty())
            if self.evidence:
                # A census already taken: nothing here touches Logic, so no pre-check, lock or switch.
                self.step("census", f"{py} Scripts/observations/label-census.py ingest {loc} "
                                    f"{shlex.quote(self.evidence)} --write --confirm")
            else:
                self.precheck()
                self.lock()
                if self.branch:
                    self.step("branch", f"git checkout -B {shlex.quote(self.branch)}")
                self.step("switch", f"Scripts/observations/locale-switch.sh {loc}")
                self.step("census", f"{py} Scripts/observations/label-census.py run {loc} --write --confirm")
            if self.navigate:
                self.step("navigate", f"{py} Scripts/observations/nav-census.py {loc} --write --confirm")
            self.step("prune", f"{py} Scripts/observations/census_pack.py prune --repoint")
            self.step("canon", f"{py} Scripts/logic_canon.py build")
            replaced = self.records_replaced() if not self.dry_run and "rebind" not in self.plan else False
            self.step("rebind", f"{py} Scripts/locale_labels.py --write" + (" --rebind" if replaced else ""))
            for _ in range(3):
                text = self.step("regenerate", f"{py} Scripts/observations/locale-regenerate.py {loc} "
                                               f"--apply --rule-only")
                if self.dry_run or "wrote 0 provenance block(s) and 0 coverage citation(s)" in text \
                        or "regenerate" in self.plan:
                    break
            self.step("ratchet", f"{py} Scripts/check-observation-ratchets.py --rebaseline "
                                 + shlex.quote(f"{self.locale} re-read on the declared Logic: readings "
                                               f"measured or held by locale_campaign.py"))
            self.step("checks", "Scripts/observations/locale-checks.sh")
            self.gather()
            self.step("commit", self.commit_command())
            self.facts["commit"] = self.head()
            self.step("preflight", f'{shlex.quote(PREFLIGHT)} "$PWD" $(git merge-base HEAD origin/main) HEAD')
            if self.push:
                self.step("lfs", "git lfs push origin HEAD")
                self.step("push", "git push origin HEAD")
                self.facts["pushed"] = True
            else:
                self.facts["pushed"] = False
        except Refusal as refusal:
            if refusal.result == "FAIL":
                self.restore()
            self.facts.update(reason=refusal.reason, failed_step=refusal.step, pushed=self.facts.get("pushed", False))
            return refusal.result
        except Exception as error:  # a crash is a FAIL too, and leaves the tree as it found it
            self.restore()
            self.facts.update(reason=f"{type(error).__name__}: {error}", failed_step="engine",
                              pushed=self.facts.get("pushed", False))
            return "FAIL"
        finally:
            self.unlock()
        held = sum(self.facts.get("holds", {}).values())
        if held:
            self.facts["reason"] = f"{held} reading(s) held; see docs/locale/holds.json"
            return "HOLD"
        return "PASS"

    # -- what the run says about itself ------------------------------------------------------------
    def head(self):
        return sh("git rev-parse --short HEAD", self.repo, capture=True)[1].strip()

    def gather(self):
        """What the run says about itself: this locale's cell counts and the readings it held."""
        if self.dry_run:
            return
        command = self.plan.get("report", f"{shlex.quote(sys.executable)} Scripts/locale_labels.py --report")
        _code, report = sh(command, self.repo, capture=True)
        for line in report.splitlines():
            parts = line.split()
            if parts and parts[0] == self.locale and len(parts) >= 9:
                names = ("current", "superseded", "unknown_version", "unverified", "derived", "unmeasured",
                         "retired", "not_measured_on_current")
                self.facts["cells"] = dict(zip(names, (int(p) for p in parts[1:9])))
        try:
            with open(os.path.join(self.repo, "docs", "locale", "holds.json"), encoding="utf-8") as handle:
                section = (json.load(handle).get("holds") or {}).get(self.locale) or {}
            self.facts["holds"] = {kind: len(items) for kind, items in section.items()}
        except (OSError, ValueError):
            self.facts["holds"] = {}

    def commit_command(self):
        cells = self.facts.get("cells") or {}
        subject = f"feat(locale): {self.locale} re-read on the declared Logic (locale_campaign.py)"
        body = (f"current {cells.get('current', '?')}, derived {cells.get('derived', '?')}, "
                f"held {self.facts.get('holds', {})}. Written by Scripts/observations/locale_campaign.py: "
                f"census, canon build, rule-only apply (exact canon match only), ratchet, every check.")
        paths = " ".join(shlex.quote(p) for p in COMMIT_PATHS)
        return (f"git add -A -- {paths} && git commit -q -m {shlex.quote(subject)} -m {shlex.quote(body)}")


def _plan_from_env():
    raw = os.environ.get("LPM_CAMPAIGN_PLAN")
    if not raw:
        return {}
    with open(raw, encoding="utf-8") as handle:
        return json.load(handle)


def result_line(result, facts):
    """The last line of every run: `RESULT: <PASS|HOLD|FAIL> <one line of JSON>`."""
    payload = dict(facts, result=result)
    return "RESULT: " + result + " " + json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def main(argv):
    flag_values = {argv[i + 1] for i, a in enumerate(argv[:-1]) if a in ("--branch", "--from-evidence")}
    args = [a for a in argv if not a.startswith("--") and a not in flag_values]
    if len(args) != 1 or args[0] not in LOCALES:
        print(result_line("FAIL", {"locale": args[0] if args else None,
                                   "reason": f"usage: locale-campaign.sh <{'|'.join(LOCALES)}>"}))
        return 1
    branch = argv[argv.index("--branch") + 1] if "--branch" in argv else None
    campaign = Campaign(args[0], repo=os.environ.get("LPM_CAMPAIGN_REPO") or REPO, dry_run="--dry-run" in argv, push="--no-push" not in argv, branch=branch,
                        navigate="--navigate" in argv,
                        evidence=argv[argv.index("--from-evidence") + 1] if "--from-evidence" in argv else None)
    result = campaign.run()
    print(result_line(result, campaign.facts))
    return {"PASS": 0, "HOLD": 10, "FAIL": 1}[result]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
