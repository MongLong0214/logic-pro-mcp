#!/usr/bin/env python3
"""Release scripts run the live gate, and published tags name the qualified commit (#985).

The live qualification tests in the suite are enabled only when `.build/release/LogicProMCP` exists, and they drive that
binary against a running Logic. Run before the release build, they drove whatever this tree built last, or were
skipped. `Scripts/release-qualify.sh` builds release, stops unless Logic is running and the new binary reports its
permissions granted, then runs the whole suite, and both release scripts call it before they tag or publish. The tag-triggered workflow checks the recorded commit before
building on a runner that cannot drive Logic.

The gate is checked by running it: `swift` and `pgrep` are stubbed on PATH, the release binary is a stub at its path,
and the calls they receive are the answer.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE = os.path.join(REPO, "Scripts", "release-qualify.sh")
TAG_CHECKER = os.path.join(REPO, "Scripts", "release-tag-is-qualified.sh")
WORKFLOW = os.path.join(REPO, ".github", "workflows", "release.yml")
CALLERS = ("release.sh", "release-stable.sh")

BUILD = ["build", "-c", "release"]
SUITE = ["test", "--no-parallel"]
PGREP = ["-xq", "Logic Pro"]
CHECK = ["--check-permissions"]

SWIFT_STUB = '#!/bin/bash\nfor a in "$@"; do printf "%s\\037" "$a"; done >> "$STUB_LOG/swift"\necho >> "$STUB_LOG/swift"\n'
PGREP_STUB = ('#!/bin/bash\nfor a in "$@"; do printf "%s\\037" "$a"; done >> "$STUB_LOG/pgrep"\necho >> "$STUB_LOG/pgrep"\n'
              'exit "$PGREP_EXIT"\n')
BINARY_STUB = ('#!/bin/bash\nfor a in "$@"; do printf "%s\\037" "$a"; done >> "$STUB_LOG/binary"\necho >> "$STUB_LOG/binary"\n'
               'exit "$PERMISSIONS_EXIT"\n')


def _calls(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\n").split("\x1f")[:-1] for line in f if line.strip("\n")]


def run_gate(gate_text, logic_running, permitted=True):
    """Run `gate_text` as Scripts/release-qualify.sh in a scratch tree.

    Returns (exit code, swift calls, pgrep calls, release binary calls)."""
    root = tempfile.mkdtemp(prefix="release-qualify-")
    try:
        os.makedirs(os.path.join(root, "Scripts"))
        os.makedirs(os.path.join(root, "bin"))
        os.makedirs(os.path.join(root, "log"))
        os.makedirs(os.path.join(root, ".build", "release"))
        for name, text in (("Scripts/release-qualify.sh", gate_text), ("bin/swift", SWIFT_STUB), ("bin/pgrep", PGREP_STUB),
                           (".build/release/LogicProMCP", BINARY_STUB)):
            path = os.path.join(root, name)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            os.chmod(path, 0o755)
        env = {
            "PATH": os.path.join(root, "bin") + ":/usr/bin:/bin",
            "STUB_LOG": os.path.join(root, "log"),
            "PGREP_EXIT": "0" if logic_running else "1",
            "PERMISSIONS_EXIT": "0" if permitted else "1",
        }
        done = subprocess.run(["/bin/bash", os.path.join(root, "Scripts", "release-qualify.sh")],
                              env=env, capture_output=True, text=True, timeout=30)
        return (done.returncode, _calls(os.path.join(root, "log", "swift")), _calls(os.path.join(root, "log", "pgrep")),
                _calls(os.path.join(root, "log", "binary")))
    finally:
        shutil.rmtree(root)


def gate_problems(gate_text):
    problems = []
    code, swift, pgrep, binary = run_gate(gate_text, logic_running=True)
    if code != 0:
        problems.append(f"with Logic running the gate exited {code}")
    if swift != [BUILD, SUITE]:
        problems.append(f"with Logic running swift received {swift}")
    if pgrep != [PGREP]:
        problems.append(f"with Logic running pgrep received {pgrep}")
    if binary != [CHECK]:
        problems.append(f"with Logic running the release binary received {binary}")
    code, swift, pgrep, binary = run_gate(gate_text, logic_running=False)
    if code == 0:
        problems.append("with no Logic running the gate exited 0")
    if swift != [BUILD]:
        problems.append(f"with no Logic running swift received {swift}")
    code, swift, pgrep, binary = run_gate(gate_text, logic_running=True, permitted=False)
    if code == 0:
        problems.append("with a permission missing the gate exited 0")
    if swift != [BUILD]:
        problems.append(f"with a permission missing swift received {swift}")
    return problems


def caller_problems(name, text):
    lines = [line.strip() for line in text.splitlines()]
    code = [(i, line) for i, line in enumerate(lines) if line and not line.startswith("#")]
    gate = [i for i, line in code if re.fullmatch(r'run "?Scripts/release-qualify\.sh"?', line)]
    direct = [line for _, line in code if re.search(r"\bswift test\b", line)]
    publish = [i for i, line in code if re.match(r'run "?(git tag|git push origin|gh release create)\b', line)]
    problems = []
    if len(gate) != 1:
        problems.append(f"{name}: expected one `run Scripts/release-qualify.sh`, found {len(gate)}")
    if direct:
        problems.append(f"{name}: runs swift test outside the gate: {direct}")
    if not publish:
        problems.append(f"{name}: no tag or publish step found to order the gate against")
    elif gate and gate[0] > publish[0]:
        problems.append(f"{name}: the gate runs after the first tag or publish step")
    return problems


def tag_record_problems(name, text):
    code = [(i, line.strip()) for i, line in enumerate(text.splitlines())
            if line.strip() and not line.lstrip().startswith("#")]
    record = [i for i, line in code if line == "QUALIFIED=$(git rev-parse HEAD)"]
    gate = [i for i, line in code if re.fullmatch(r'run "?Scripts/release-qualify\.sh"?', line)]
    tags = [line for _, line in code if re.match(r'run "?git tag\b', line)]
    problems = []
    if len(record) != 1 or not gate or record[0] >= gate[0]:
        problems.append(f"{name}: record qualified HEAD before the live gate")
    if not tags or any("Live-qualified: $QUALIFIED" not in line for line in tags):
        problems.append(f"{name}: tag must name the qualified commit")
    return problems


def workflow_problems(text):
    build = re.search(r"(?m)^  build-release:\s*$", text)
    publish = re.search(r"(?m)^  publish:\s*$", text)
    if not build or not publish or build.start() >= publish.start():
        return ["release.yml: build-release must precede publish"]
    block = text[build.end():publish.start()]
    check = re.search(r'(?m)^\s+Scripts/release-tag-is-qualified\.sh "\$\{GITHUB_REF_NAME\}"\s*$', block)
    suite = re.search(r"(?m)^\s+- name: Run test suite\s*$", block)
    problems = []
    if not check:
        problems.append("release.yml: build-release lacks tag qualification step")
    elif not suite or check.start() >= suite.start():
        problems.append("release.yml: tag qualification must precede the test suite")
    return problems


SHA_LINE = '  sha256 "' + "a" * 64 + '"\n'
FORMULA = ('class LogicProMcp < Formula\n  url "https://example.invalid/v1.2.2.tar.gz"\n'
           + SHA_LINE + 'end\n')
TWO_SHA_FORMULA = FORMULA.replace(SHA_LINE, SHA_LINE + '  sha256 "' + "c" * 64 + '"\n')
HEADER_LIKE_FORMULA = FORMULA.replace("end\n", "-- extra\nend\n")
#: The release.sh checksum rewrite and Formula edits it must never make after qualification.
FORMULA_CHANGES = {
    "formula-checksum": ("Formula/logic-pro-mcp.rb", FORMULA.replace("a" * 64, "b" * 64)),
    "formula-url": ("Formula/logic-pro-mcp.rb", FORMULA.replace("v1.2.2", "v9.9.9")),
    "formula-checksum-and-url": ("Formula/logic-pro-mcp.rb",
                                 FORMULA.replace("a" * 64, "b" * 64).replace("v1.2.2", "v9.9.9")),
    "formula-checksum-deleted": ("Formula/logic-pro-mcp.rb", FORMULA.replace(SHA_LINE, "")),
    "formula-checksum-added": ("Formula/logic-pro-mcp.rb",
                               FORMULA.replace(SHA_LINE, SHA_LINE + '  sha256 "' + "b" * 64 + '"\n')),
    "formula-checksum-and-indent": ("Formula/logic-pro-mcp.rb",
                                   FORMULA.replace(SHA_LINE, '    sha256 "' + "b" * 64 + '"\n')),
    "formula-checksum-and-header-like-addition": ("Formula/logic-pro-mcp.rb",
                                                  FORMULA.replace("a" * 64, "b" * 64)
                                                  .replace("end\n", "++ extra\nend\n")),
    "formula-checksum-and-header-like-deletion": ("Formula/logic-pro-mcp.rb",
                                                  HEADER_LIKE_FORMULA.replace("a" * 64, "b" * 64)
                                                  .replace("-- extra\n", "")),
    "formula-two-checksums-replaced": ("Formula/logic-pro-mcp.rb",
                                       TWO_SHA_FORMULA.replace("a" * 64, "b" * 64).replace("c" * 64, "d" * 64)),
}


def run_tag_check(check_text, *, qualified="tagged", changes=(), tag_kind="annotated",
                  message_lines=None, commit_live_line=False, formula_before=FORMULA):
    """Run the tag checker in a real, isolated scratch git repo; return its exit code."""
    with tempfile.TemporaryDirectory(prefix="release-tag-") as root:
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update({
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Release Test", "GIT_AUTHOR_EMAIL": "release-test@example.invalid",
            "GIT_COMMITTER_NAME": "Release Test", "GIT_COMMITTER_EMAIL": "release-test@example.invalid",
            "GIT_AUTHOR_DATE": "2020-01-01T00:00:00+0000", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00+0000",
        })

        def git(*args):
            return subprocess.run(["git", *args], cwd=root, env=env, capture_output=True,
                                  text=True, check=True).stdout.strip()

        git("init", "-q")
        for name, text in (("Formula/logic-pro-mcp.rb", formula_before), ("Sources/Example.swift", "before\n")):
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        git("add", ".")
        git("commit", "-qm", "base")
        parent = git("rev-parse", "HEAD")

        if changes:
            for change in changes:
                name, text = FORMULA_CHANGES.get(change, (change, "after\n"))
                with open(os.path.join(root, name), "w", encoding="utf-8") as f:
                    f.write(text)
            git("add", ".")
            message = "Release commit\n\nLive-qualified: " + parent if commit_live_line else "release change"
            git("commit", "-qm", message)
        tagged = git("rev-parse", "HEAD")
        sha = {"tagged": tagged, "parent": parent, "missing": "0" * 40}[qualified]

        if tag_kind == "lightweight":
            git("tag", "v1.2.3")
        else:
            lines = ["Live-qualified: " + sha] if message_lines is None else message_lines
            lines = [line.replace("{qualified}", sha) for line in lines]
            args = ["tag", "-a", "v1.2.3", "-m", "Release v1.2.3"]
            for line in lines:
                args.extend(("-m", line))
            git(*args)

        path = os.path.join(root, "Scripts", "release-tag-is-qualified.sh")
        os.makedirs(os.path.dirname(path))
        with open(path, "w", encoding="utf-8") as f:
            f.write(check_text)
        os.chmod(path, 0o755)
        done = subprocess.run(["/bin/bash", path, "v1.2.3"], cwd=root, env=env,
                              capture_output=True, text=True, timeout=30)
        return done.returncode


def tag_checker_problems(check_text):
    cases = (
        ("annotated tag naming tagged commit", {}, 0),
        ("Formula checksum change", {"qualified": "parent", "changes": ("formula-checksum",)}, 0),
        ("Formula url change", {"qualified": "parent", "changes": ("formula-url",)}, 1),
        ("Formula checksum and url change", {"qualified": "parent", "changes": ("formula-checksum-and-url",)}, 1),
        ("Formula checksum deletion", {"qualified": "parent", "changes": ("formula-checksum-deleted",)}, 1),
        ("Formula second checksum addition", {"qualified": "parent", "changes": ("formula-checksum-added",)}, 1),
        ("Formula checksum and indentation change", {"qualified": "parent",
                                                     "changes": ("formula-checksum-and-indent",)}, 1),
        ("Formula checksum and header-like addition", {"qualified": "parent",
                                                       "changes": ("formula-checksum-and-header-like-addition",)}, 1),
        ("Formula checksum and header-like deletion", {"qualified": "parent",
                                                       "changes": ("formula-checksum-and-header-like-deletion",),
                                                       "formula_before": HEADER_LIKE_FORMULA}, 1),
        ("Formula two checksum replacements", {"qualified": "parent", "changes": ("formula-two-checksums-replaced",),
                                               "formula_before": TWO_SHA_FORMULA}, 1),
        ("source change", {"qualified": "parent", "changes": ("Sources/Example.swift",)}, 1),
        ("lightweight tag", {"qualified": "parent", "changes": ("formula-checksum",),
                             "tag_kind": "lightweight", "commit_live_line": True}, 1),
        ("missing line", {"message_lines": []}, 1),
        ("duplicate lines", {"message_lines": ["Live-qualified: {qualified}"] * 2}, 1),
        ("malformed sha", {"message_lines": ["Live-qualified: abc123"]}, 1),
        ("missing commit without origin", {"qualified": "missing"}, 1),
    )
    problems = []
    for name, kwargs, expected in cases:
        code = run_tag_check(check_text, **kwargs)
        if (code == 0) != (expected == 0):
            problems.append(f"tag checker: {name} exited {code}")
    return problems


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class TheGateBehaves(unittest.TestCase):
    def test_the_repository_gate(self):
        self.assertEqual(gate_problems(_read(GATE)), [])

    def test_a_gate_that_continues_without_logic_is_refused(self):
        broken = _read(GATE).replace("    exit 1\n", "    :\n", 1)
        self.assertNotEqual(broken, _read(GATE))
        self.assertIn("with no Logic running the gate exited 0", gate_problems(broken))

    def test_a_gate_that_runs_part_of_the_suite_is_refused(self):
        broken = _read(GATE).replace("swift test --no-parallel", "swift test --filter VersionConsistencyTests", 1)
        self.assertNotEqual(broken, _read(GATE))
        self.assertTrue(any(p.startswith("with Logic running swift received") for p in gate_problems(broken)))

    def test_a_gate_that_tests_before_it_builds_is_refused(self):
        text = _read(GATE)
        broken = text.replace("swift build -c release\n", "", 1).replace(
            "swift test --no-parallel\n", "swift test --no-parallel\nswift build -c release\n", 1)
        self.assertNotEqual(broken, text)
        self.assertNotEqual(gate_problems(broken), [])

    def test_a_gate_that_skips_the_permission_check_is_refused(self):
        broken = _read(GATE).replace("if ! .build/release/LogicProMCP --check-permissions; then", "if false; then", 1)
        self.assertNotEqual(broken, _read(GATE))
        self.assertIn("with a permission missing the gate exited 0", gate_problems(broken))

    def test_a_gate_that_continues_without_a_permission_is_refused(self):
        text = _read(GATE)
        head, tail = text.split("--check-permissions; then", 1)
        broken = head + "--check-permissions; then" + tail.replace("    exit 1\n", "    :\n", 1)
        self.assertNotEqual(broken, text)
        self.assertIn("with a permission missing the gate exited 0", gate_problems(broken))

    def test_a_gate_that_looks_for_another_process_is_refused(self):
        broken = _read(GATE).replace('pgrep -xq "Logic Pro"', 'pgrep -xq "Finder"', 1)
        self.assertIn("with Logic running pgrep received [['-xq', 'Finder']]", gate_problems(broken))


class EveryReleaseScriptRunsTheGate(unittest.TestCase):
    def test_the_repository_release_scripts(self):
        for name in CALLERS:
            with self.subTest(name=name):
                self.assertEqual(caller_problems(name, _read(os.path.join(REPO, "Scripts", name))), [])

    def test_a_script_that_runs_the_suite_itself_is_refused(self):
        text = 'run "swift test --no-parallel"\nrun "swift build -c release"\nrun "gh release create v1"\n'
        self.assertEqual(caller_problems("x", text), [
            "x: expected one `run Scripts/release-qualify.sh`, found 0",
            "x: runs swift test outside the gate: ['run \"swift test --no-parallel\"']",
        ])

    def test_a_gate_after_the_tag_is_refused(self):
        text = 'run git tag "$VERSION" -m x\nrun Scripts/release-qualify.sh\n'
        self.assertEqual(caller_problems("x", text), ["x: the gate runs after the first tag or publish step"])


class TagsNameTheLiveQualifiedCommit(unittest.TestCase):
    def test_the_repository_tag_checker(self):
        self.assertEqual(tag_checker_problems(_read(TAG_CHECKER)), [])

    def test_checker_without_the_diff_restriction_is_refused(self):
        text = _read(TAG_CHECKER)
        broken = text.replace('if [ -n "$changed" ] && [ "$changed" != "Formula/logic-pro-mcp.rb" ]; then',
                              'if false; then', 1)
        self.assertNotEqual(broken, text)
        self.assertTrue(any("source change" in p for p in tag_checker_problems(broken)))

    def test_checker_allowing_any_formula_edit_is_refused(self):
        text = _read(TAG_CHECKER)
        broken = text.replace('if [ "$changed" = "Formula/logic-pro-mcp.rb" ]; then',
                              'if false; then', 1)
        self.assertNotEqual(broken, text)
        self.assertIn("tag checker: Formula url change exited 0", tag_checker_problems(broken))

    def test_checker_accepting_a_lightweight_tag_is_refused(self):
        text = _read(TAG_CHECKER)
        broken = text.replace('if [ "$(git cat-file -t "$tag_ref" 2>/dev/null || true)" != "tag" ]; then',
                              'if false; then', 1)
        self.assertNotEqual(broken, text)
        self.assertTrue(any("lightweight tag" in p for p in tag_checker_problems(broken)))

    def test_release_scripts_record_qualified_head(self):
        for name in CALLERS:
            with self.subTest(name=name):
                self.assertEqual(tag_record_problems(name, _read(os.path.join(REPO, "Scripts", name))), [])

    def test_a_caller_without_the_tag_line_is_refused(self):
        for name in CALLERS:
            with self.subTest(name=name):
                text = _read(os.path.join(REPO, "Scripts", name))
                broken = text.replace(" -m 'Live-qualified: $QUALIFIED'", "", 1) if name == "release.sh" else (
                    text.replace(' -m "Live-qualified: $QUALIFIED"', "", 1))
                self.assertNotEqual(broken, text)
                self.assertIn(f"{name}: tag must name the qualified commit", tag_record_problems(name, broken))

    def test_the_workflow_checks_the_tag_before_tests_and_publish(self):
        self.assertEqual(workflow_problems(_read(WORKFLOW)), [])

    def test_a_workflow_without_the_tag_step_is_refused(self):
        text = _read(WORKFLOW)
        start = text.index("      - name: Refuse a tag with no live qualification named\n")
        end = text.index("      - name: Select Xcode", start)
        broken = text[:start] + text[end:]
        self.assertIn("release.yml: build-release lacks tag qualification step", workflow_problems(broken))


if __name__ == "__main__":
    unittest.main()
