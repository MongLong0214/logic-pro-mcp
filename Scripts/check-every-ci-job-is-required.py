#!/usr/bin/env python3
"""A CI job that nothing requires is decoration, and this repository has built three of them.

The `build` job is the only required context the branch ruleset looks at. A job outside its `needs`
list can run, can go red, and the merge is permitted anyway.

Three times now:

    the roadmap job          restored in one change, added to `needs` only after a review caught it
    ci-verify-formula-sha    orphaned when the roadmap job was deleted; invoked by nothing for weeks
    the canon citation job   added by the change whose own subject is enforcement sites drifting
                             from named sites, and left out of `needs` in that same change

The third is the one that made this guard worth writing. The lesson was already recorded as a
comment four lines above the list, in the file being edited, and it was repeated anyway -- which is
what a comment can and cannot do.

So: every job in the workflow is in `build.needs`, or is named here with a reason. The waiver list
may only shrink.

Scope is now DECLARED rather than assumed. `ci.yml` carries the required gate and is the workflow
whose jobs are audited against `build.needs`. Every other workflow file must be named in
`docs/canon/CI-GATE.json` under `workflows`, with `gates_merges` and a reason -- and a file nobody
named is a failure.

That last rule is the same rule as the first one, moved up a level. The three defects above are all
"a thing that can fail exists, and the required context does not look at it", and a WORKFLOW is a
thing that can fail. Splitting the roadmap check into `maintenance.yml` on 2026-09-18 created the
first file this guard would otherwise have had no opinion about, and the next one could just as
easily be a gate nobody wired up.

`required_commands` is per-workflow for the same reason. Moving a command out of `ci.yml` and
leaving its string in this guard's list would have kept a test looking in the wrong file; moving it
out and checking nothing would have lost the step silently. The command follows the workflow.
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(REPO, ".github", "workflows", "ci.yml")
GATE = "build"

#: Jobs outside the required gate, and the COMMANDS the workflow must still carry, both read from
#: a file. Held as module constants first, which meant a job could be excused -- or a step deleted
#: -- in the same commit that did it: the hole `check-canon-citations.py`'s rule 7 exists to close,
#: open here while that rule guarded three other lists.
#:
#: `required_commands` exists because a JOB being required says nothing about its STEPS. The
#: tree-wide citation check runs with `--changed` in one step of one job, and deleting that step
#: leaves the job green and the check unaimed.
POLICY_PATH = os.path.join(REPO, "docs", "canon", "CI-GATE.json")


WORKFLOW_DIR = os.path.join(REPO, ".github", "workflows")
AUDITED = "ci.yml"


def policy() -> dict:
    with open(POLICY_PATH, "r", encoding="utf-8") as handle:
        loaded = json.load(handle)
    for key in ("not_required", "required_commands", "workflows"):
        if key not in loaded:
            raise SystemExit(f"{POLICY_PATH}: no `{key}`")
    return loaded


def check_workflows(rules: dict, problems: list) -> None:
    """Every workflow file is declared, and every declaration is of a file that exists."""
    declared = rules["workflows"]
    on_disk = sorted(name for name in os.listdir(WORKFLOW_DIR)
                     if name.endswith((".yml", ".yaml")))
    for name in on_disk:
        entry = declared.get(name)
        if entry is None:
            problems.append(
                f".github/workflows/{name}: no entry in {os.path.relpath(POLICY_PATH, REPO)}. "
                f"Say whether it gates a merge and why. A workflow nobody declared is a thing that "
                f"can fail while the required context does not look at it -- which is the defect "
                f"this whole guard is about, one level up.")
            continue
        if "gates_merges" not in entry or not str(entry.get("why") or "").strip():
            problems.append(
                f".github/workflows/{name}: its entry needs `gates_merges` and a `why` with "
                f"something in it. A waiver with no reason is a list.")
            continue
        if entry["gates_merges"] and name != AUDITED:
            problems.append(
                f".github/workflows/{name}: declares that it gates merges, and this guard only "
                f"audits {AUDITED}. Either audit it here or say it does not gate.")
        path = os.path.join(WORKFLOW_DIR, name)
        with open(path, "r", encoding="utf-8") as handle:
            body = handle.read()
        for command in entry.get("required_commands") or []:
            if command not in body:
                problems.append(
                    f".github/workflows/{name}: no step runs `{command}`. It is declared as this "
                    f"workflow's, so moving it elsewhere means moving the declaration too -- and "
                    f"deleting it means deleting the check.")
    for name in sorted(set(declared) - set(on_disk)):
        problems.append(
            f"{os.path.relpath(POLICY_PATH, REPO)}: `workflows` names `{name}`, which is not a "
            f"file in .github/workflows. A declaration for something that does not exist is "
            f"bookkeeping that outlived its reason.")


def jobs_and_needs(text: str):
    """The workflow's job names and the gate's `needs`, read without a YAML dependency.

    Parsed by indentation rather than with PyYAML because this guard runs in the same plain-Python
    contract as the rest of `run-repo-guards.py`, which deliberately has no third-party imports.
    The shapes it must handle are the two this file uses: a flow sequence on one line, and a block
    sequence of `- name` lines.
    """
    lines = text.splitlines()
    names, needs, in_jobs = [], [], False
    for index, line in enumerate(lines):
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if in_jobs and line and not line[0].isspace():
            in_jobs = False
        if not in_jobs:
            continue
        stripped = line.strip()
        if (line.startswith("  ") and not line.startswith("   ")
                and stripped.endswith(":") and not stripped.startswith("#")):
            names.append(stripped[:-1])
        if stripped.startswith("needs:") and _owner(lines, index) == GATE:
            rest = stripped[len("needs:"):].strip()
            if rest.startswith("["):
                needs = [item.strip().strip("'\"") for item in rest[1:-1].split(",") if item.strip()]
            else:
                cursor = index + 1
                while cursor < len(lines) and lines[cursor].strip().startswith("- "):
                    needs.append(lines[cursor].strip()[2:].strip().strip("'\""))
                    cursor += 1
    return names, needs


def _owner(lines, index):
    """The job whose block `lines[index]` sits in."""
    for cursor in range(index, -1, -1):
        line = lines[cursor]
        stripped = line.strip()
        if (line.startswith("  ") and not line.startswith("   ")
                and stripped.endswith(":") and not stripped.startswith("#")):
            return stripped[:-1]
    return None


def check(path: str = WORKFLOW):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    names, needs = jobs_and_needs(text)
    problems = []
    if GATE not in names:
        return [f"{path}: there is no `{GATE}` job, so nothing here knows what the required gate is"]
    if not needs:
        problems.append(f"{path}: `{GATE}` has no `needs`, so it requires nothing")
    rules = policy()
    not_required = rules["not_required"]
    for job in names:
        if job in needs or job in not_required:
            continue
        problems.append(
            f"{path}: job `{job}` is in no required gate. It can run, it can fail, and the merge is "
            f"permitted anyway. Add it to `{GATE}.needs`, or name it in NOT_REQUIRED with why.")
    for job in sorted(not_required):
        if job not in names:
            problems.append(f"{path}: NOT_REQUIRED names `{job}`, which is not a job in this "
                            f"workflow. A waiver for something that does not exist is bookkeeping "
                            f"that outlived its reason.")
    for job in sorted(set(needs) - set(names)):
        problems.append(f"{path}: `{GATE}.needs` names `{job}`, which is not a job in this workflow")
    # A job that reads the PULL REQUEST BODY is only as good as the events that start it.
    # `pull_request:` with no `types:` defaults to opened, synchronize and reopened -- `edited` is
    # NOT among them -- so the body gate saw the body as of the last PUSH and never again. Open a
    # compliant pull request, let it go green, edit the citations out: nothing re-runs. The rule
    # named the body; the enforcement site was the push.
    if "--text" in text and "pull_request:" in text:
        trigger = re.search(r"^\s*types:\s*\[([^\]]*)\]", text, re.M)
        listed = {t.strip() for t in (trigger.group(1) if trigger else "").split(",") if t.strip()}
        if "edited" not in listed:
            problems.append(
                f"{path}: a step runs `--text` over the pull request body, and the `pull_request` "
                f"trigger does not list `edited`. The default types are opened, synchronize and "
                f"reopened, so the body could be rewritten after the gate went green and nothing "
                f"would re-read it.")

    # A gate whose bar the gated change can set is not a bar.
    #
    # `ci-coverage-gate.sh` reads its floors from `LPM_COVERAGE_MIN_REGION` and
    # `LPM_COVERAGE_MIN_LINE`, defaulting to 70 and 78. A pull request runs its OWN copy of
    # `ci.yml`, so adding `env: LPM_COVERAGE_MIN_LINE: "0"` to the gate step lowers the threshold
    # for exactly the change being judged -- and with `required_approving_review_count: 0` on the
    # branch ruleset, nobody is required to read the diff that does it. The seam has to exist for
    # the gate's own self-test, which is why it is refused HERE rather than removed there.
    for setting in ("LPM_COVERAGE_MIN_REGION", "LPM_COVERAGE_MIN_LINE", "LPM_COVERAGE_TARGET"):
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("#") or not stripped.startswith(setting):
                continue
            problems.append(
                f"{path}: this workflow sets `{setting}`. The coverage floors are read from the "
                f"environment so the gate's self-test can drive them; a pull request runs its own "
                f"copy of this file, so setting one here lets a change choose the bar it is "
                f"measured against. Change the default in Scripts/ci-coverage-gate.sh instead, "
                f"where the diff says what the new floor is.")

    check_workflows(rules, problems)

    for command in rules["required_commands"]:
        if command not in text:
            problems.append(
                f"{path}: no step runs `{command}`. A required JOB says nothing about its STEPS, "
                f"and deleting a step leaves the job green with the check unaimed.")
    return problems


def main() -> int:
    problems = check()
    if problems:
        print(f"{len(problems)} problem(s) with the required gate:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    names, needs = jobs_and_needs(open(WORKFLOW, encoding="utf-8").read())
    rules = policy()
    gating = [n for n, e in rules["workflows"].items() if e.get("gates_merges")]
    print(f"every one of {len(names)} CI job(s) is required by `{GATE}` or waived with a reason "
          f"({len(needs)} required, {len(rules['not_required'])} waived); "
          f"{len(rules['required_commands'])} required command(s) present; "
          f"{len(rules['workflows'])} workflow(s) declared, {len(gating)} gating merges")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
