#!/usr/bin/env python3
"""Drive `Scripts/ci-coverage-gate.sh` through each state it must refuse, with no Xcode and no tests.

The gate was 90 lines inline in `ci.yml`. Inline, the only way to see it refuse anything was to
push a branch whose coverage had actually dropped, which is why four of the refusals below had
never been observed at all -- including the one that matters most: a report built from a profile
this run did not produce.

`LPM_LLVM_COV` points the report command at a fake that prints whatever the case wants, and
`LPM_COVERAGE_BUILD_DIR` at a tree the case builds. Neither is a convenience: without them a
coverage gate can only be tested by having bad coverage.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

GATE = Path(__file__).resolve().parent / "ci-coverage-gate.sh"
BIN_REL = ("x86_64-apple-macosx/debug/LogicProMCPPackageTests.xctest/Contents/MacOS/"
           "LogicProMCPPackageTests")
PROF_REL = "x86_64-apple-macosx/debug/codecov/default.profdata"

#: llvm-cov's TOTAL columns: regions, missed, cover%, functions, missed, cover%, lines, missed,
#: cover%. Field 4 is region cover, field 10 is line cover -- which is what the gate extracts.
def total(region="82.50%", line="88.00%"):
    return f"TOTAL 1000 175 {region} 200 20 90.00% 5000 600 {line}\n"


def _tree(root, bins=1, profs=1, sources=1):
    for index in range(bins):
        path = Path(root, f"arch{index}", *BIN_REL.split("/")[1:])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("binary")
    for index in range(profs):
        path = Path(root, f"arch{index}", *PROF_REL.split("/")[1:])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("profile")
    src = Path(root, "src")
    src.mkdir(parents=True, exist_ok=True)
    for index in range(sources):
        Path(src, f"File{index}.swift").write_text("// swift\n")
    return src


#: The header real llvm-cov writes above the rows. The gate reads the column NAMES from it to
#: check that region and line cover are still the third and ninth data columns, so a fixture
#: without one is testing a report shape the tool does not produce.
HEADER = ("Filename                    Regions    Missed Regions     Cover   Functions"
          "  Missed Functions  Executed       Lines      Missed Lines     Cover"
          "    Branches   Missed Branches     Cover\n"
          "------------------------------------------------------------------------\n")


def run(report_text, bins=1, profs=1, sources=1, header=HEADER, **env_overrides):
    """Run the gate over a fixture tree and a fake `llvm-cov` that prints `report_text`.

    `header` defaults to the real one; a case testing the column names passes its own, and one
    testing a headerless report passes "".
    """
    report_text = header + report_text
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        build = root / "build"
        build.mkdir()
        src = _tree(build, bins=bins, profs=profs, sources=sources)
        fake = root / "fake-llvm-cov"
        fake.write_text("#!/usr/bin/env bash\ncat <<'REPORT'\n" + report_text + "REPORT\n")
        fake.chmod(0o755)
        env = dict(os.environ,
                   LPM_COVERAGE_BUILD_DIR=str(build),
                   LPM_COVERAGE_SOURCES=str(src),
                   LPM_COVERAGE_REPORT=str(root / "report.txt"),
                   LPM_LLVM_COV=str(fake))
        env.pop("GITHUB_STEP_SUMMARY", None)
        env.update({k: str(v) for k, v in env_overrides.items()})
        proc = subprocess.run(["bash", str(GATE)], capture_output=True, text=True, env=env,
                              cwd=tmp)
        return proc.returncode, proc.stdout + proc.stderr


def main():
    failures = []

    def check(name, condition, detail):
        if not condition:
            failures.append(f"{name}: {detail}")

    good = "Filename Regions Missed Cover Functions Missed Cover Lines Missed Cover\n" + total()

    rc, out = run(good)
    check("coverage above both floors passes", rc == 0, f"exit {rc}: {out.strip()[:250]}")

    # A05 -- the shape a stale cached profile takes once the fresh one is also there. The gate
    # cannot tell which is this run's, and picking is what it must not do.
    rc, out = run(good, profs=2)
    check("two profdata files are refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("two profdata says which", "found 1 and 2" in out, out.strip()[:250])

    rc, out = run(good, bins=2, profs=2)
    check("two test binaries are refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")

    rc, out = run(good, bins=0, profs=0)
    check("no binary and no profile is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("an absent profile is not a pass", "found 0 and 0" in out, out.strip()[:250])

    # A06 -- the report itself.
    rc, out = run("", header="")
    check("an empty report is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("an empty report says so", "empty" in out, out.strip()[:250])

    rc, out = run("Filename Regions\nsomething else entirely\n")
    check("a report with no TOTAL is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("no TOTAL says how many", "has 0 TOTAL lines" in out, out.strip()[:250])

    rc, out = run(total() + total())
    check("two TOTAL lines are refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("two TOTAL lines says how many", "has 2 TOTAL lines" in out, out.strip()[:250])

    # The column-order guard, three ways, because they are caught by different checks and an
    # outside review found that only one of the three was caught at all. The record for this file
    # said as much in its own Limit: the shape check "has only been driven by a synthetic shifted
    # column".
    #
    # A PREPENDED column pushes an INTEGER into field 4, so the percentage pattern refuses it.
    rc, out = run("TOTAL extra 1000 175 82.50% 200 20 90.00% 5000 600 88.00%\n")
    check("a prepended column is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("a prepended column names the pattern", "<float>% pattern" in out, out.strip()[:250])

    # A field SWAPPED in place keeps the count, so the pattern check is what has to catch it.
    rc, out = run("TOTAL 1000 175 82.50% 200 20 90.00% 5000 600 not-a-percent\n")
    check("a field that is not a percentage is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("and names the pattern", "<float>% pattern" in out, out.strip()[:250])

    # THIRTEEN FIELDS IS THE NORMAL REPORT, and asserting otherwise broke the gate in CI. Real
    # llvm-cov on the runner appends `Branches Missed-Branches Cover` after the line group:
    #
    #   TOTAL  24107  4929  79.55%  6698  1199  82.10%  74463  9266  87.56%  0  0  -
    #
    # Appending does NOT move fields 4 and 10. The first version of this case demanded ten fields,
    # which is a shape the tool does not produce, and the `test` job went red on a report that was
    # entirely correct. A count cannot tell an append from an insertion; both give thirteen.
    rc, out = run("TOTAL 24107 4929 79.55% 6698 1199 82.10% 74463 9266 87.56% 0 0 -\n")
    check("the real thirteen-column report is accepted", rc == 0, f"exit {rc}: {out.strip()[:250]}")

    # WHAT AN INSERTION LOOKS LIKE, and it is the header that tells them apart. A group ahead of
    # `Lines` that this gate does not account for moves line cover out of field 10 while leaving a
    # percentage sitting there.
    inserted = ("Filename    Regions    Missed Regions     Cover   Functions  Missed Functions"
                "  Executed    Branches   Missed Branches     Cover       Lines      Missed Lines"
                "     Cover\n----\n")
    rc, out = run("TOTAL 1000 175 82.50% 200 20 90.00% 300 30 91.00% 5000 600 88.00%\n",
                  header=inserted)
    check("a group inserted before Lines is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("and names the column that moved", "before Lines" in out, out.strip()[:250])

    # A report with no header at all is refused rather than read positionally on faith.
    rc, out = run(total(), header="")
    check("a headerless report is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")

    # A TRUNCATED line. The percentage pattern would refuse this too -- field 10 is empty and an
    # empty string is not `<float>%` -- so this case exists for the MESSAGE, which is the whole
    # reason the length check is separate: a report that stops early reads as a column-order
    # change otherwise, and the gate's own comment says to say which it is. Without this case the
    # length check could be deleted and every case would stay green, which is the definition of a
    # check nobody has watched fail.
    rc, out = run("TOTAL 1000 175 82.50% 200 20 90.00%\n")
    check("a truncated TOTAL line is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("and is refused AS truncation, not as a column-order change",
          "field 10 is the line coverage" in out, out.strip()[:250])

    rc, out = run(total(region="NaN%"))
    check("NaN region coverage is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")

    rc, out = run(total(line="not-a-number"))
    check("a non-numeric line coverage is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")

    # The thresholds themselves, in both directions and at the boundary.
    rc, out = run(total(region="69.99%"))
    check("region below the floor fails", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("region below the floor says the number", "69.99% below threshold 70%" in out,
          out.strip()[:250])

    rc, out = run(total(line="77.99%"))
    check("line below the floor fails", rc == 1, f"exit {rc}: {out.strip()[:250]}")

    rc, out = run(total(region="70.00%", line="78.00%"))
    check("exactly at both floors passes", rc == 0, f"exit {rc}: {out.strip()[:250]}")

    # Below the 90% TARGET is a notice, not a gate -- raising it silently would make every
    # release red, which is why it is a separate number.
    rc, out = run(total(line="88.00%"))
    check("below the target is not a failure", rc == 0, f"exit {rc}: {out.strip()[:250]}")
    check("below the target says so", "below the 90% target" in out, out.strip()[:250])

    # Measuring nothing is not 100%. Exit 1 alone does not prove this case: on BSD `xargs` an
    # empty file list means llvm-cov is never invoked, so the EMPTY-REPORT refusal below catches it
    # and the case would be green with this check deleted. On GNU `xargs` the command DOES run,
    # with no source arguments, and llvm-cov reports the whole binary -- a different measurement,
    # reported as this one. The message is what separates the two.
    rc, out = run(good, sources=0)
    check("no sources to measure is refused", rc == 1, f"exit {rc}: {out.strip()[:250]}")
    check("no sources is refused AS no sources", "measure nothing" in out,
          f"this must not pass through the empty-report branch: {out.strip()[:250]}")

    # A floor this repository does not use, to prove the thresholds are read rather than baked in.
    rc, out = run(total(region="82.50%"), LPM_COVERAGE_MIN_REGION="90")
    check("a raised floor is honoured", rc == 1, f"exit {rc}: {out.strip()[:250]}")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print("31 case(s) pass: the coverage gate refuses an ambiguous profile, an unreadable report, "
          "a shifted column and a missed floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
