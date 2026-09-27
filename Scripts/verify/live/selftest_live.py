#!/usr/bin/env python3
"""Drive the live library once, in Korean and one other locale; the exit code is the verdict.

Usage:  /usr/bin/python3 Scripts/verify/live/selftest_live.py [--head <sha>] [--locales ko de]
                                                             [--evidence-root <dir>]

Steps, each recorded raw with the predicate that judged it (its source text is stored beside it):

  build             binary.build(head): built by construction, re-hashed here
  exclusivity       exclusive.claim: the lock taken, no other server or test bundle running
  per locale:
    switch          locale.switch_to(lproj): Logic's AppleLanguages and the arrange title from
                    Apple's `Tracks` row
    fixture_reset   fixture.reset("locale_campaign_mixer"): Don't Save, reopen, show the Mixer; then
                    both fixtures' fingerprints read and compared with their declarations
    screen_clean    screen.settle_to_clean, then no dirt
    positive_control/<probe>  every registered probe on the reset fixture reports its known reading
    server          the built binary started and initialized
    must_fail       the #1020 arm probe after arming track 0 through the server must DISAGREE with
                    its pre-state reading (the control FAILS, as it must), then the disarm restores
                    every track's flags
    server_stop     the server stopped, pid verified gone
    screen_clean_after  no dirt after the drive
  restore           locale.restore_locale("ko"), confirmed the same way
  final             the resting state read once more (Korean, fixture, clean screen)

The evidence is written to <evidence-root>/<head>/selftest.json whatever happens. The lock is
released in a `finally`. Nothing here decides anything by a flag an author wrote: every verdict is a
predicate over a recorded observation.

This file must not be run with its own directory first on sys.path (`locale.py` would shadow the
standard library); the lines below put the parent directory there instead.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if sys.path and os.path.abspath(sys.path[0] or ".") == HERE:
    sys.path[0] = os.path.dirname(HERE)
else:
    sys.path.insert(0, os.path.dirname(HERE))

import argparse  # noqa: E402
import inspect  # noqa: E402
import json  # noqa: E402
import socket  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402

from live import binary, exclusive, fixture, mcp, obs, probes, screen  # noqa: E402
from live import locale as live_locale  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
EVIDENCE_ROOT = "/Users/isaac/lpm-evidence/verify-live-selftest"
LOCK_WAIT_S = 1800
MUST_FAIL_TRACK = 0


# ---------------------------------------------------------------------------------------------
# predicates: pure, over recorded observations
# ---------------------------------------------------------------------------------------------

def pred_build(o):
    return (o.get("binding") == "built-by-verifier" and bool(o.get("binary_path"))
            and o.get("rehash") == o.get("binary_sha256") and o.get("head") == o.get("asked_head"))


def pred_exclusive(o):
    return (bool((o.get("lock") or {}).get("acquired")) and not o.get("refused")
            and (o.get("competing") or {}).get("readable") is True
            and (o.get("competing") or {}).get("value") == [])


def pred_switch(o):
    return live_locale.in_locale(o.get("after") or {})


def pred_fixture_reset(o):
    reset = o.get("reset") or {}
    mixer_fp = ((reset.get("read") or {}).get("fingerprint")) or {}
    other_fp = ((o.get("read_19") or {}).get("fingerprint")) or {}
    return (fixture.fingerprint_matches(fixture.spec("locale_campaign_mixer"), mixer_fp)
            and fixture.fingerprint_matches(fixture.spec("locale_campaign_19"), other_fp))


def pred_screen_clean(o):
    return o.get("final", {}).get("dirt") == []


def pred_server(o):
    init = (o.get("start") or {}).get("initialize") or {}
    return bool((o.get("start") or {}).get("spawned")) and "result" in (init.get("reply") or {})


def pred_server_stop(o):
    return (o.get("stop") or {}).get("pid_gone") is True


def flags_of(run):
    observation = (run or {}).get("observation") or {}
    if not observation.get("readable"):
        return None
    return [{f: t[f] for f in ("arm", "mute", "solo")} for t in observation["tracks"]]


def pred_arm_probe_agrees_with_pre_state(o):
    """The control predicate that MUST be false after the arm: track 0's arm reads as before."""
    pre, post = flags_of(o.get("pre")), flags_of(o.get("post"))
    if pre is None or post is None:
        return None
    return post[MUST_FAIL_TRACK]["arm"] == pre[MUST_FAIL_TRACK]["arm"]


def pred_must_fail(o):
    """The control failed as it must, on track 0's arm and nothing else, and the disarm restored.

    "Nothing else" keeps the control aimed: a probe reading the wrong row would also disagree.
    """
    pre, post, after = flags_of(o.get("pre")), flags_of(o.get("post")), flags_of(o.get("after"))
    if pre is None or post is None or after is None or len(pre) != len(post):
        return False
    post_but_the_arm = [dict(row) for row in post]
    post_but_the_arm[MUST_FAIL_TRACK]["arm"] = pre[MUST_FAIL_TRACK]["arm"]
    return (pred_arm_probe_agrees_with_pre_state(o) is False
            and post_but_the_arm == pre
            and after == pre)


# ---------------------------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------------------------

class Run:
    def __init__(self, head):
        self.doc = {"schema": "lpm-verify-live-selftest/1", "head": head, "host": socket.gethostname(),
                    "python": sys.version, "started_unix": time.time(), "t0": obs.now(),
                    "steps": []}

    def step(self, name, observation, predicate, lproj=None):
        try:
            verdict = predicate(observation)
        except Exception as exc:  # noqa: BLE001 - a predicate that raised did not pass
            verdict, observation = False, {**observation, "predicate_raised": repr(exc)}
        self.doc["steps"].append({"step": name, "lproj": lproj, "t": obs.now(),
                                  "passed": verdict is True, "predicate": predicate.__name__,
                                  "predicate_source": inspect.getsource(predicate),
                                  "observation": observation})
        print(f"{'PASS' if verdict is True else 'FAIL'} {name}{' [' + lproj + ']' if lproj else ''}",
              flush=True)
        return verdict is True


def drive_locale(run, lproj, built):
    step = lambda name, o, p: run.step(name, o, p, lproj)  # noqa: E731
    step("switch", live_locale.switch_to(lproj), pred_switch)

    reset = fixture.reset("locale_campaign_mixer", lproj)
    step("fixture_reset", {"reset": reset, "read_19": fixture.read("locale_campaign_19", lproj)},
         pred_fixture_reset)

    step("screen_clean", screen.settle_to_clean(timeout_s=10.0), pred_screen_clean)

    for name, probe in probes.REGISTRY.items():
        control = probe["positive_control"]
        args = {"lproj": lproj}
        if "fixture" in probe["schema"]:
            args["fixture"] = fixture.spec(control["fixture"])["path"]
        observed = {"screen": screen.sample(), "run": probes.run(name, args),
                    "fixture": control["fixture"], "reading": control["reading"]}
        known = control["known"]
        spec = fixture.spec(control["fixture"])

        def pred_positive_control(o, known=known, spec=spec):
            return known(spec, (o.get("run") or {}).get("observation") or {})

        pred_positive_control.__name__ = f"positive_control_{name}"
        step(f"positive_control/{name}", observed, pred_positive_control)

    server = mcp.Server(built["binary_path"])
    try:
        start = server.start(init_timeout_s=60)
        step("server", {"start": start}, pred_server)
        fp = fixture.read("locale_campaign_19", lproj, server) if start.get("spawned") else None
        pre = probes.run("track_flags_ax", {"lproj": lproj})
        arm = server.tool("logic_tracks", "arm", {"index": MUST_FAIL_TRACK, "enabled": True},
                          timeout_s=90)
        post = probes.run("track_flags_ax", {"lproj": lproj})
        disarm = server.tool("logic_tracks", "arm", {"index": MUST_FAIL_TRACK, "enabled": False},
                             timeout_s=90)
        after = probes.run("track_flags_ax", {"lproj": lproj})
        control = {"pre": pre, "arm": arm, "post": post, "disarm": disarm, "after": after,
                   "control_predicate_result": None, "fixture_read_with_product": fp}
        control["control_predicate_result"] = pred_arm_probe_agrees_with_pre_state(control)
        step("must_fail", control, pred_must_fail)
    finally:
        stop = server.stop()
        step("server_stop", {"stop": stop, "server": server.record()}, pred_server_stop)
    step("screen_clean_after", screen.settle_to_clean(timeout_s=10.0), pred_screen_clean)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--head")
    parser.add_argument("--locales", nargs="+", default=["ko", "de"])
    parser.add_argument("--evidence-root", default=EVIDENCE_ROOT)
    args = parser.parse_args()
    unknown = [lp for lp in args.locales if lp not in live_locale.LOCALES]
    if unknown:
        parser.error(f"unknown lproj(s): {unknown}")
    head = args.head or obs.run(["git", "-C", REPO, "rev-parse", "HEAD"], 10)["stdout"].strip()
    run = Run(head)
    out_dir = os.path.join(args.evidence_root, head)
    os.makedirs(out_dir, exist_ok=True)
    try:
        built = binary.build(head, REPO)
        if built.get("binary_path"):
            built["rehash"] = binary.sha256_of(built["binary_path"])
        built["asked_head"] = head
        if not run.step("build", built, pred_build):
            return finish(run, out_dir)
        record = {}
        with exclusive.claim("#1028 verifier live self-test", LOCK_WAIT_S, record) as held:
            run.step("exclusivity", record, pred_exclusive)
            if not held:
                return finish(run, out_dir)
            run.doc["as_found"] = {"reading": live_locale.reading(live_locale.RESTING),
                                   "screen": screen.clean_state()}
            try:
                for lproj in args.locales:
                    drive_locale(run, lproj, built)
            finally:
                run.step("restore", live_locale.restore_locale(live_locale.RESTING), pred_switch,
                         live_locale.RESTING)
                final = {"reading": live_locale.reading(live_locale.RESTING),
                         "screen": screen.settle_to_clean(timeout_s=10.0)}
                run.step("final", final, lambda o: live_locale.in_locale(o["reading"])
                         and o["screen"]["final"]["dirt"] == [])
        run.doc["lock_record"] = record
    except Exception:  # noqa: BLE001 - recorded, and the run fails
        run.doc["crash"] = traceback.format_exc()
        print(run.doc["crash"], file=sys.stderr)
    return finish(run, out_dir)


def finish(run, out_dir):
    steps = run.doc["steps"]
    run.doc["finished_unix"] = time.time()
    run.doc["verdict"] = {"steps": len(steps), "passed": sum(1 for s in steps if s["passed"]),
                          "failed": [f"{s['step']}[{s['lproj']}]" for s in steps if not s["passed"]],
                          "crashed": "crash" in run.doc}
    ok = bool(steps) and not run.doc["verdict"]["failed"] and "crash" not in run.doc
    run.doc["verdict"]["exit"] = 0 if ok else 1
    path = os.path.join(out_dir, "selftest.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(run.doc, handle, ensure_ascii=False, indent=1, default=repr)
    print(json.dumps({"evidence": path, **run.doc["verdict"]}, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
