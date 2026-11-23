#!/usr/bin/env python3
"""The restored canon, locale and native gates are unconditional inputs to required `build`."""
import os
import re
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        return handle.read()


def job_body(workflow, name):
    match = re.search(rf"^  {re.escape(name)}:\n", workflow, re.M)
    if not match:
        return None
    tail = workflow[match.end():]
    next_job = re.search(r"^  [A-Za-z0-9_-]+:\n", tail, re.M)
    return tail[:next_job.start()] if next_job else tail


def native_consumer_script(workflow):
    native = job_body(workflow, "native-logic-e2e") or ""
    match = re.search(
        r'python3 - "\$RUNNER_TEMP/combined-status\.json".*?<<\'PY\'\n(.*?)\n          PY',
        native,
        re.S,
    )
    if not match:
        raise AssertionError("native status consumer heredoc not found")
    return textwrap.dedent(match.group(1))


def step_script(workflow, job, step):
    body = job_body(workflow, job) or ""
    match = re.search(rf"^      - name: {re.escape(step)}\n(.*?)(?=^      - |\Z)",
                      body, re.M | re.S)
    if not match:
        raise AssertionError(f"{job}/{step} not found")
    script = re.search(r"^        run: \|\n(.*)", match.group(1), re.M | re.S)
    if not script:
        raise AssertionError(f"{job}/{step} has no shell script")
    return textwrap.dedent(script.group(1))


def history_reading_scripts():
    """Every `Scripts/check-*.py` that compares against the merge base or a ratchet."""
    scripts = pathlib.Path(REPO, "Scripts")
    return sorted(
        path.name for path in scripts.glob("check-*.py")
        if re.search(r"merge[-_]base|ratchet", path.read_text(encoding="utf-8"), re.I)
    )


def history_checkout_problems(workflow, scripts):
    """Jobs that run a history-reading script without a full-history checkout."""
    problems = []
    for match in re.finditer(r"^  ([A-Za-z0-9_-]+):\n", workflow, re.M):
        job = match.group(1)
        body = job_body(workflow, job) or ""
        used = [name for name in scripts if re.search(rf"Scripts/{re.escape(name)}\b", body)]
        if not used:
            continue
        checkouts = re.findall(
            r"- uses: actions/checkout@\S+.*?\n((?:        .*\n)*)", body)
        if not checkouts:
            problems.append(f"{job}: runs {used[0]} with no checkout step")
        for options in checkouts:
            if not re.search(r"^          fetch-depth: 0\s*$", options, re.M):
                problems.append(f"{job}: runs {used[0]} but its checkout lacks fetch-depth: 0")
    return problems


def workflow_problems(workflow):
    problems = []
    canon = job_body(workflow, "canon-locales") or ""
    native = job_body(workflow, "native-logic-e2e") or ""
    build = job_body(workflow, "build") or ""
    release = job_body(workflow, "release-build") or ""
    shards = job_body(workflow, "test-shards") or ""
    build_needs = re.search(r"^    needs:\s*(.*)$", build, re.M)
    build_dependencies = build_needs.group(1) if build_needs else ""
    if not canon:
        problems.append("missing canon-locales job")
    if re.search(r"^    if:.*(docs|full-validation|change-scope)", canon, re.M):
        problems.append("canon-locales is path-conditional")
    mutation = re.search(
        r"^      - name: Mutation drives prove tampering, stale canon and wrong locale maps fail\n"
        r"(.*?)(?=^      - |\Z)", canon, re.M | re.S)
    if mutation and re.search(r"^        if:", mutation.group(1), re.M):
        problems.append("required mutation step is conditional")
    for indent, body in ((4, canon), (8, mutation.group(1) if mutation else "")):
        tolerated = re.search(rf"^{' ' * indent}continue-on-error:\s*([^\n]+)", body, re.M)
        if tolerated and tolerated.group(1).split("#", 1)[0].strip() != "false":
            problems.append("canon-locales tolerates a required verification failure")
    for command in (
        "Scripts/check-canon-drift.py",
        "Scripts/check-canon-citations.py",
        "Scripts/check-policy-literals-against-canon.py",
        "Scripts/check-labelsets-are-derived.py",
        "Scripts/check-new-labelsets-name-a-row.py",
        "Scripts/check-labelset-census-only-shrinks.py",
        "Scripts/check-locale-labels-json.py",
        "Scripts/check-locale-detection-is-derived.py",
        "Scripts/check-locale-policy-coverage.py",
        "Scripts/check-observation-records.py",
        "Scripts/test_logic_canon.py",
        "Scripts/locale_labels.py --check",
        "Scripts/test_canon_citations_guard.py",
        "Scripts/test_labelsets_are_derived.py",
        "Scripts/test_new_labelsets_name_a_row.py",
        "Scripts/test_release_verify_candidate.py",
        "Scripts/test_locale_detection_is_derived.py",
    ):
        if command not in canon:
            problems.append(f"canon-locales does not run {command}")
    if not native:
        problems.append("missing native-logic-e2e job")
    if "logic-native-e2e" not in native or "Native PASS a=" not in native:
        problems.append("native job does not consume the exact live status")
    for binding in ("EXPECTED_ATTEMPT", "release-runtime-{run_id}-{expected_attempt}",
                    'commits/$EXPECTED_SHA/status?per_page=100',
                    'commits/$EXPECTED_SHA/statuses?per_page=100',
                    'gh api --paginate --slurp',
                    'status_response.get("sha")',
                    'artifact.get("digest")', 'artifact.get("id")'):
        if binding not in native:
            problems.append(f"native job does not bind {binding}")
    if re.search(r"^    if:.*(docs|full-validation|change-scope)", native, re.M):
        problems.append("native gate is path-conditional")
    if re.search(r"^    if:.*full-validation", release, re.M):
        problems.append("release artifact is skipped for documentation changes")
    attempt_artifact = "release-runtime-${{ github.run_id }}-${{ github.run_attempt }}"
    if attempt_artifact not in release:
        problems.append("release artifact is not bound to the run attempt")
    if attempt_artifact not in shards:
        problems.append("test shards do not download the run-attempt artifact")
    for dependency in ("canon-locales", "native-logic-e2e"):
        if dependency not in build_dependencies:
            problems.append(f"required build does not depend on {dependency}")
    for result in ("CANON_LOCALES", "NATIVE_LOGIC"):
        if f'test "${result}" = success' not in build:
            problems.append(f"required build does not fail on {result}")
    return problems


# The jobs that compile, run and merge the coverage-instrumented tests, and the one that builds the
# exact artifact native qualification runs. They share one architecture because a profile is only
# valid against the binary that wrote it.
MACOS_JOBS = ("release-build", "test-build", "test-shards", "product-validation")
MACOS_LABEL = "macos-15"


def runner_problems(workflow):
    """Runner labels and job structure of the macOS path, as measured and chosen in ci.yml."""
    problems = []
    declared = re.findall(r"^    runs-on:\s*(.*?)\s*$", workflow, re.M)
    for label in declared:
        if "intel" in label or re.search(r"macos-(?!15\b)", label):
            problems.append(f"unmeasured or Intel macOS label: {label}")
    for name in MACOS_JOBS:
        body = job_body(workflow, name) or ""
        runs_on = re.search(r"^    runs-on:\s*(.*?)\s*$", body, re.M)
        if not runs_on:
            problems.append(f"{name}: missing runs-on")
        elif name == "product-validation":
            if runs_on.group(1) != (
                    "${{ needs.change-scope.outputs.full-validation == 'true' && "
                    f"'{MACOS_LABEL}' || 'ubuntu-latest' }}}}"):
                problems.append(f"{name}: runs-on is not {MACOS_LABEL} for full validation")
        elif runs_on.group(1) != MACOS_LABEL:
            problems.append(f"{name}: runs-on is {runs_on.group(1)}, not {MACOS_LABEL}")
    release = job_body(workflow, "release-build") or ""
    if 'test "$(lipo -archs .build/release/LogicProMCP)" = arm64' not in release:
        problems.append("release-build does not assert the release-runtime artifact is arm64")
    build = job_body(workflow, "test-build") or ""
    if 'test "$(lipo -archs "$test_binary")" = arm64' not in build:
        problems.append("test-build does not assert the coverage test binary is arm64")
    shards = job_body(workflow, "test-shards") or ""
    if not re.search(r"^      max-parallel: 2$", shards, re.M):
        problems.append("test-shards no longer caps its simultaneous macOS allocations at 2")
    if re.findall(r"^          - shard: (\w+)$", shards, re.M) != ["selected", "complement"]:
        problems.append("test-shards no longer runs exactly the selected and complement shards")
    for dependency in ("release-build", "test-build", "test-shards"):
        needs = re.search(r"^    needs:\s*(.*)$", job_body(workflow, "product-validation") or "", re.M)
        if not needs or dependency not in needs.group(1):
            problems.append(f"product-validation does not wait for {dependency}")
    return problems


class RequiredVerificationWorkflow(unittest.TestCase):
    def test_real_workflow_is_fail_closed(self):
        self.assertEqual(workflow_problems(read(".github/workflows/ci.yml")), [])

    def test_only_a_regular_roadmap_edit_can_use_the_documentation_shortcut(self):
        script = step_script(read(".github/workflows/ci.yml"), "change-scope",
                             "Classify changed paths")
        mutations = {
            "roadmap": lambda root: (root / "docs/roadmap/README.md").write_text("updated\n"),
            "consumed_readme": lambda root: (root / "README.md").write_text("updated\n"),
            "canon": lambda root: (root / "docs/canon/MANIFEST.json").write_text("{}\n"),
            "locale": lambda root: (root / "docs/locale/ui-labels.json").write_text("{}\n"),
            "source_to_docs": lambda root: (root / "Sources/source.swift").rename(root / "docs/source.md"),
            "deleted": lambda root: (root / "docs/roadmap/README.md").unlink(),
            "added_roadmap": lambda root: (root / "docs/roadmap/README.md").write_text("new\n"),
            "executable": lambda root: (root / "docs/roadmap/README.md").chmod(0o755),
            "symlink": lambda root: ((root / "docs/roadmap/README.md").unlink(),
                                     (root / "docs/roadmap/README.md").symlink_to("../../README.md")),
            "mixed": lambda root: ((root / "docs/roadmap/README.md").write_text("updated\n"),
                                   (root / "README.md").write_text("updated\n")),
            "empty": lambda root: None,
            "diff_failure": lambda root: None,
        }
        for case, mutate in mutations.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_AUTHOR_NAME="Test", GIT_COMMITTER_NAME="Test",
                           GIT_AUTHOR_EMAIL="test@example.invalid",
                           GIT_COMMITTER_EMAIL="test@example.invalid")
                def git(*args):
                    return subprocess.check_output(["git", *args], cwd=root, env=env, text=True)
                git("init", "-q")
                for path in ("docs/roadmap/README.md", "README.md", "Sources/source.swift",
                             "docs/canon/MANIFEST.json", "docs/locale/ui-labels.json"):
                    file = root / path
                    file.parent.mkdir(parents=True, exist_ok=True)
                    if case != "added_roadmap" or path != "docs/roadmap/README.md":
                        file.write_text("baseline\n")
                git("add", ".")
                git("commit", "-qm", "baseline")
                base = git("rev-parse", "HEAD").strip()
                mutate(root)
                git("add", "-A")
                git("commit", "-qm", "candidate", "--allow-empty")
                output = root / "output"
                result = subprocess.run(["bash", "-c", script], cwd=root, text=True,
                    capture_output=True, env=dict(env, BASE_SHA="missing" if case == "diff_failure" else base,
                        GITHUB_SHA=git("rev-parse", "HEAD").strip(),
                        GITHUB_OUTPUT=str(output), RUNNER_TEMP=str(root)))
                if case == "diff_failure":
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(output.exists(), "a failed diff must not publish a scope")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = "docs-only" if case == "roadmap" else "full"
                    self.assertIn(f"mode={expected}\n", output.read_text())
                    native = "true" if case in ("source_to_docs", "symlink", "empty") else "false"
                    self.assertIn(f"native-required={native}\n", output.read_text())

    def test_real_locale_refusals_reach_the_required_gate_even_for_docs_only(self):
        workflow = read(".github/workflows/ci.yml")
        canon = step_script(workflow, "canon-locales",
                            "Verify pinned Apple corpus, citations and every declared locale")
        fan_in = step_script(workflow, "build", "Product validation must pass")
        source = read("Sources/LogicProMCP/Accessibility/AXLogicProElements+Menu.swift")
        mutations = {
            "wrong_translation": ('"Ablage", "Bearbeiten", "Spur"',
                                  '"Datei", "Bearbeiten", "Spur"'),
            "missing_locale": ('("zh-TW", ["檔案", "編輯", "音軌"]),', ""),
        }
        for case, (old, new) in mutations.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                self.assertIn(old, source)
                root = pathlib.Path(directory)
                policy = root / "Menu.swift"
                policy.write_text(source.replace(old, new, 1))
                # Other validators are healthy producers in this isolated propagation test.
                # The failing producer executes the real guard against the mutated Swift file.
                runner = root / "python3"
                runner.write_text(f"#!{sys.executable}\nimport os,sys\n"
                    "if sys.argv[1] == 'Scripts/check-locale-detection-is-derived.py':\n"
                    f"    os.execv(sys.executable, [sys.executable, {os.path.join(REPO, 'Scripts/check-locale-detection-is-derived.py')!r}])\n")
                runner.chmod(0o755)
                result = subprocess.run(["bash", "-c", canon], cwd=REPO, text=True,
                    capture_output=True, env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                                                 LPM_POLICY_SWIFT=str(policy)))
                self.assertNotEqual(result.returncode, 0, f"{case}: {result.stdout} {result.stderr}")
                self.assertIn("problem(s) with locale detection", result.stderr)
                result = subprocess.run(["bash", "-c", fan_in], text=True, capture_output=True,
                    env=dict(os.environ, MODE="docs-only", SCOPE="success", CANON_LOCALES="failure",
                             NATIVE_LOGIC="success", VALIDATION="success", PRODUCT="skipped",
                             DOCS_ONLY="success"))
                self.assertNotEqual(result.returncode, 0, "a failed locale gate reached required success")

    def test_required_fan_in_rejects_every_non_success_verification_result(self):
        script = step_script(read(".github/workflows/ci.yml"), "build", "Product validation must pass")
        healthy = dict(os.environ, MODE="docs-only", SCOPE="success", CANON_LOCALES="success",
                       NATIVE_LOGIC="success", VALIDATION="success", PRODUCT="skipped", DOCS_ONLY="success")
        self.assertEqual(subprocess.run(["bash", "-c", script], env=healthy).returncode, 0)
        for field in ("CANON_LOCALES", "NATIVE_LOGIC"):
            for state in ("failure", "cancelled", "skipped", ""):
                with self.subTest(field=field, state=state):
                    result = subprocess.run(["bash", "-c", script], env=dict(healthy, **{field: state}))
                    self.assertNotEqual(result.returncode, 0)

    def _assert_release_candidate_suite_blocks(self, workflow):
        self.assertEqual(workflow_problems(workflow), [])
        script = step_script(workflow, "canon-locales",
                             "Mutation drives prove tampering, stale canon and wrong locale maps fail")
        fan_in = step_script(workflow, "build", "Product validation must pass")
        target = "Scripts/test_release_verify_candidate.py"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            runner = root / "python3"
            # The unchanged producer suite drives the real verifier CLI. This probe isolates
            # wiring: only that producer's controlled nonzero may fail the actual shell step.
            runner.write_text(f"#!{sys.executable}\nimport os,sys\n"
                "with open(os.environ['TRACE'], 'a') as out: out.write(sys.argv[1] + '\\n')\n"
                f"if sys.argv[1] == {target!r}: sys.exit(int(os.environ['TARGET_EXIT']))\n")
            runner.chmod(0o755)
            for status in (0, 23):
                trace = root / str(status)
                result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                    env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                             TRACE=str(trace), TARGET_EXIT=str(status)))
                self.assertEqual(trace.read_text().splitlines().count(target), 1,
                                 "the required mutation step must invoke the release suite exactly once")
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                gate = subprocess.run(["bash", "-c", fan_in], text=True, capture_output=True,
                    env=dict(os.environ, MODE="docs-only", SCOPE="success",
                             CANON_LOCALES="failure" if result.returncode else "success",
                             NATIVE_LOGIC="success", VALIDATION="success", PRODUCT="skipped",
                             DOCS_ONLY="success"))
                self.assertEqual(gate.returncode == 0, status == 0, gate.stdout + gate.stderr)

    def test_release_candidate_suite_runs_and_blocks_required_build_even_for_docs_only(self):
        self._assert_release_candidate_suite_blocks(read(".github/workflows/ci.yml"))

    def test_release_candidate_suite_cannot_be_dropped_or_its_failure_tolerated(self):
        workflow = read(".github/workflows/ci.yml")
        target = "Scripts/test_release_verify_candidate.py"
        self.assertTrue(target in workflow, "required release suite invocation is absent")
        step = "      - name: Mutation drives prove tampering, stale canon and wrong locale maps fail\n"
        mutations = {
            "deleted": workflow.replace(target, "", 1),
            "commented": workflow.replace(target, "# " + target, 1),
            "failure_swallowed": workflow.replace('python3 "$test_file"',
                                                   'python3 "$test_file" || true', 1),
            "docs_condition": workflow.replace(step, step + "        if: needs.change-scope.outputs.mode != 'docs-only'\n", 1),
            "step_tolerates_failure": workflow.replace(step, step + "        continue-on-error: true\n", 1),
            "job_tolerates_failure": workflow.replace("  canon-locales:\n",
                                                       "  canon-locales:\n    continue-on-error: true\n", 1),
        }
        for case, mutated in mutations.items():
            with self.subTest(case=case), self.assertRaises(AssertionError):
                self._assert_release_candidate_suite_blocks(mutated)

    def test_real_labelset_proofs_reach_required_build_even_for_docs_only(self):
        workflow = read(".github/workflows/ci.yml")
        canon = step_script(workflow, "canon-locales",
                            "Verify pinned Apple corpus, citations and every declared locale")
        fan_in = step_script(workflow, "build", "Product validation must pass")
        row_guard = "Scripts/check-new-labelsets-name-a-row.py"
        census_guard = "Scripts/check-labelset-census-only-shrinks.py"
        waiver_path = "docs/canon/LABELSETS-WITHOUT-A-ROW.json"
        census_path = "docs/canon/LABELSETS-WITHOUT-A-ROW-LEGACY.json"
        policy_path = os.path.join(REPO, "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift")
        cases = (("valid_composition", row_guard, None),
                 ("valid_census", census_guard, None),
                 ("wrong_composition_factor", row_guard, "template_values[de]"),
                 ("missing_composition_locale", row_guard, "missing locales ['es']"),
                 ("omitted_waiver", census_guard, "transportRecordArmExclusion"),
                 ("omitted_legacy", census_guard, "automationModeTrim"))
        for case, guard, diagnostic in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                waivers = json.loads(read(waiver_path))
                census = json.loads(read(census_path))
                if case == "wrong_composition_factor":
                    waivers["labelsets"]["showLibraryMenuItem"]["composed_from"]["template_values"]["de"] = "Wrong %@"
                elif case == "missing_composition_locale":
                    composition = waivers["labelsets"]["showLibraryMenuItem"]["composed_from"]
                    del composition["template_values"]["es"]
                    del composition["noun_values"]["es"]
                elif case == "omitted_waiver":
                    del waivers["labelsets"]["transportRecordArmExclusion"]
                elif case == "omitted_legacy":
                    del census["undeclared"]["automationModeTrim"]
                (root / "waivers.json").write_text(json.dumps(waivers))
                (root / "census.json").write_text(json.dumps(census))
                invoked = root / "invoked"
                # Isolate the producer under test; other commands are healthy. Both guards
                # execute their real main(), using the committed source/corpus and disposable
                # inputs. The row guard has no waiver-path environment seam, so only that
                # input path is redirected after loading it; no predicate/canon is replaced.
                runner = root / "python3"
                runner.write_text(f"#!{sys.executable}\nimport importlib.util,os,sys\n"
                    f"with open({str(invoked)!r}, 'a') as out: out.write(sys.argv[1] + '\\n')\n"
                    f"if sys.argv[1] == {row_guard!r}:\n"
                    f"    spec = importlib.util.spec_from_file_location('row_guard', {os.path.join(REPO, row_guard)!r})\n"
                    "    module = importlib.util.module_from_spec(spec)\n"
                    "    spec.loader.exec_module(module)\n"
                    "    module.WAIVERS = os.environ['LPM_LABELSET_WAIVERS']\n"
                    "    sys.exit(module.main())\n"
                    f"if sys.argv[1] == {census_guard!r}:\n"
                    f"    os.execv(sys.executable, [sys.executable, {os.path.join(REPO, census_guard)!r}])\n")
                runner.chmod(0o755)
                env = dict(os.environ, CI="true", PATH=directory + os.pathsep + os.environ["PATH"],
                           LPM_LABELSET_WAIVERS=str(root / "waivers.json"),
                           LPM_LABELSET_CENSUS=str(root / "census.json"),
                           LPM_LABELSET_BASE_JSON=os.path.join(REPO, census_path),
                           LPM_LABELSET_BASE_POLICY=policy_path)
                direct = subprocess.run([str(runner), guard], cwd=REPO, env=env,
                                        text=True, capture_output=True)
                expected = 1 if diagnostic else 0
                self.assertEqual(direct.returncode, expected, direct.stdout + direct.stderr)
                if diagnostic:
                    self.assertIn(diagnostic, direct.stderr)
                invoked.unlink()
                result = subprocess.run(["bash", "-c", canon], cwd=REPO, env=env,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(guard, invoked.read_text().splitlines())
                if diagnostic:
                    self.assertIn(diagnostic, result.stderr)
                gate = subprocess.run(["bash", "-c", fan_in], text=True, capture_output=True,
                    env=dict(os.environ, MODE="docs-only", SCOPE="success",
                             CANON_LOCALES="failure" if result.returncode else "success",
                             NATIVE_LOGIC="success", VALIDATION="success", PRODUCT="skipped",
                             DOCS_ONLY="success"))
                self.assertEqual(gate.returncode, expected, gate.stdout + gate.stderr)

    def test_real_policy_coverage_guard_refuses_an_omitted_label_set(self):
        source = read("Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift")
        block = re.search(r"static let allLabelSets: \[LabelSet\] = \[(.*?)\n    \]", source, re.S)
        self.assertIsNotNone(block)
        entry = re.search(r"^        [A-Za-z0-9_]+,\n", block.group(1), re.M).group()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            script = root / "Scripts/check-locale-policy-coverage.py"
            script.parent.mkdir()
            shutil.copy2(os.path.join(REPO, "Scripts/check-locale-policy-coverage.py"), script)
            policy = root / "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift"
            policy.parent.mkdir(parents=True)
            policy.write_text(source)
            control = subprocess.run([sys.executable, str(script)], text=True, capture_output=True)
            self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
            policy.write_text(source[:block.start(1)] + block.group(1).replace(entry, "", 1)
                              + source[block.end(1):])
            result = subprocess.run([sys.executable, str(script)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("is missing 1", result.stdout)
            self.assertIn(entry.strip().rstrip(","), result.stdout)

    def test_docs_only_condition_is_detected(self):
        workflow = read(".github/workflows/ci.yml").replace(
            "  canon-locales:\n", "  canon-locales:\n    if: needs.change-scope.outputs.full-validation == 'true'\n", 1)
        self.assertIn("canon-locales is path-conditional", workflow_problems(workflow))

    def test_detaching_native_from_required_build_is_detected(self):
        workflow = read(".github/workflows/ci.yml").replace(
            "needs: [change-scope, canon-locales, native-logic-e2e, product-validation]",
            "needs: [change-scope, canon-locales, product-validation]", 1)
        self.assertIn("required build does not depend on native-logic-e2e",
                      workflow_problems(workflow))

    def test_native_status_can_only_follow_the_real_gate(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        qualifier = wrapper.index('bash "$TRUSTED_ROOT/Scripts/release-qualify.sh"')
        success = wrapper.index('post_status success "$receipt"')
        self.assertLess(qualifier, success)
        self.assertIn('test "$(cat "$work/runtime/candidate-sha.txt")" = "$SHA"', wrapper)
        self.assertIn('post_status failure "Exact artifact failed native Logic qualification"', wrapper)
        self.assertNotIn("LOGIC_PRO_MCP_RUN_LIVE_QA=0", wrapper)

    def test_native_candidate_binds_the_run_base_and_head(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        self.assertIn('run.get("head_sha") != head_sha', wrapper)
        self.assertIn('parents != [base_sha, head_sha]', wrapper)
        self.assertNotIn('run.get("head_sha") != expected_sha', wrapper)

    def test_native_host_separates_trust_from_candidate(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        self.assertIn('require_release_origin "$TRUSTED_ROOT"', wrapper)
        self.assertIn('require_release_origin "$CANDIDATE_ROOT"', wrapper)
        self.assertIn('["git", "-C", sys.argv[6], "show"', wrapper)
        self.assertIn('rev-parse origin/main', wrapper)
        self.assertIn('"$TRUSTED_ROOT/Scripts/release-qualify.sh"', wrapper)
        self.assertIn('${LOGIC_NATIVE_STATUS_TOKEN+x}', wrapper)
        self.assertIn('if ! IFS= read -r status_token || [ -z "$status_token" ]; then', wrapper)
        self.assertNotIn('GH_TOKEN="$status_token"', wrapper)
        self.assertIn('env -u GH_TOKEN -u GITHUB_TOKEN -u LOGIC_NATIVE_STATUS_TOKEN -u status_token', wrapper)
        self.assertIn('"$work/runtime/LogicProMCP" "$CANDIDATE_ROOT" < /dev/null', wrapper)

    def test_required_job_accepts_only_the_trusted_status_publisher(self):
        workflow = read(".github/workflows/ci.yml")
        native = job_body(workflow, "native-logic-e2e") or ""
        self.assertIn("actions: read", native)
        self.assertIn('creator.get("login") != "MongLong0214"', native)
        self.assertIn('creator.get("id") != 97578200', native)

    def test_native_receipt_binds_run_attempt_and_current_artifact_bytes(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        workflow = read(".github/workflows/ci.yml")
        native = job_body(workflow, "native-logic-e2e") or ""
        for required in ("run_attempt", "artifact_id", "artifact_digest", "runtime.zip"):
            self.assertIn(required, wrapper)
        for required in ("EXPECTED_ATTEMPT", 'artifact.get("id")',
                         'artifact.get("digest")', "Native PASS a=",
                         "release-runtime-{run_id}-{expected_attempt}"):
            self.assertIn(required, native)

    def test_run_attempt_artifact_binding_cannot_be_removed_silently(self):
        workflow = read(".github/workflows/ci.yml").replace(
            "release-runtime-${{ github.run_id }}-${{ github.run_attempt }}",
            "release-runtime-${{ github.run_id }}")
        problems = workflow_problems(workflow)
        self.assertIn("release artifact is not bound to the run attempt", problems)
        self.assertIn("test shards do not download the run-attempt artifact", problems)

    def test_replaced_artifact_binding_cannot_be_removed_silently(self):
        workflow = read(".github/workflows/ci.yml").replace(
            'artifact.get("digest")', 'None', 1)
        self.assertIn('native job does not bind artifact.get("digest")',
                      workflow_problems(workflow))

    def test_combined_status_sha_binding_cannot_be_removed_silently(self):
        workflow = read(".github/workflows/ci.yml").replace(
            'status_response.get("sha")', 'None', 1)
        self.assertIn('native job does not bind status_response.get("sha")',
                      workflow_problems(workflow))

    def test_combined_status_accepts_a_realistic_row_without_sha(self):
        sha = "a" * 40
        run_id = "123"
        attempt = "2"
        digest = "b" * 64
        target = f"https://github.com/MongLong0214/logic-pro-mcp/actions/runs/{run_id}/attempts/{attempt}"
        receipt = f"Native PASS a={attempt} id=42 d={digest}"
        status = {
            "sha": sha,
        }
        status_pages = [[{
                "context": "logic-native-e2e",
                "target_url": target,
                "state": "success",
                "description": receipt,
                "creator": {"login": "MongLong0214", "id": 97578200},
        }]]
        artifacts = {"artifacts": [{
            "name": f"release-runtime-{run_id}-{attempt}",
            "expired": False,
            "id": 42,
            "digest": f"sha256:{digest}",
        }]}
        with tempfile.TemporaryDirectory() as directory:
            status_path = os.path.join(directory, "status.json")
            status_pages_path = os.path.join(directory, "status-pages.json")
            artifacts_path = os.path.join(directory, "artifacts.json")
            with open(status_path, "w", encoding="utf-8") as handle:
                json.dump(status, handle)
            with open(status_pages_path, "w", encoding="utf-8") as handle:
                json.dump(status_pages, handle)
            with open(artifacts_path, "w", encoding="utf-8") as handle:
                json.dump(artifacts, handle)
            result = subprocess.run(
                ["python3", "-", status_path, status_pages_path, artifacts_path,
                 sha, target, attempt, run_id],
                input=native_consumer_script(read(".github/workflows/ci.yml")),
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Current run-attempt artifact passed native Logic qualification", result.stdout)

    def test_combined_status_rejects_a_wrong_top_level_sha(self):
        workflow = read(".github/workflows/ci.yml")
        script = native_consumer_script(workflow)
        self.assertIn('status_response.get("sha") != expected_sha', script)
        self.assertNotIn('latest.get("sha")', script)
        with tempfile.TemporaryDirectory() as directory:
            status_path = os.path.join(directory, "status.json")
            status_pages_path = os.path.join(directory, "status-pages.json")
            artifacts_path = os.path.join(directory, "artifacts.json")
            with open(status_path, "w", encoding="utf-8") as handle:
                json.dump({"sha": "b" * 40}, handle)
            with open(status_pages_path, "w", encoding="utf-8") as handle:
                json.dump([[]], handle)
            with open(artifacts_path, "w", encoding="utf-8") as handle:
                json.dump({"artifacts": []}, handle)
            result = subprocess.run(
                ["python3", "-", status_path, status_pages_path, artifacts_path, "a" * 40,
                 "https://example.invalid/attempt", "1", "123"],
                input=script,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("combined native status response SHA mismatch", result.stderr)

    def test_release_gate_uses_real_logic_and_exact_bytes(self):
        gate = read("Scripts/release-qualify.sh")
        for required in (
            'pgrep -xq "Logic Pro"',
            ".build/release/LogicProMCP --check-permissions",
            "realReleaseBinaryExecutesEveryOperationWithIndependentReadback",
            "runnerRejectsPartialStateObservedFromRealServer",
            "verify_candidate_bytes",
            "Scripts/logic_canon.py status",
        ):
            self.assertIn(required, gate)
        self.assertNotIn("skip", gate.lower())

    def test_every_job_that_reads_git_history_checks_out_full_history(self):
        scripts = history_reading_scripts()
        self.assertIn("check-canon-citations.py", scripts)
        self.assertIn("check-observation-ratchets.py", scripts)
        for name in ("ci.yml", "release.yml"):
            self.assertEqual(
                history_checkout_problems(read(f".github/workflows/{name}"), scripts), [], name)

    def test_a_checkout_without_full_history_is_detected(self):
        scripts = history_reading_scripts()
        release = read(".github/workflows/release.yml")
        shallow = release.replace(
            "        with:\n          ref: ${{ inputs.candidate_sha }}\n          fetch-depth: 0\n",
            "        with:\n          ref: ${{ inputs.candidate_sha }}\n", 1)
        self.assertNotEqual(shallow, release)
        problems = history_checkout_problems(shallow, scripts)
        self.assertTrue(any(p.startswith("candidate-package:") for p in problems), problems)


    def test_macos_path_uses_one_measured_arm64_label_and_keeps_its_structure(self):
        self.assertEqual(runner_problems(read(".github/workflows/ci.yml")), [])

    def test_a_job_moved_to_another_macos_label_is_detected(self):
        workflow = read(".github/workflows/ci.yml")
        for name, label in (("release-build", "macos-15-intel"), ("test-build", "macos-26"),
                            ("test-shards", "macos-14")):
            with self.subTest(job=name, label=label):
                body = job_body(workflow, name)
                moved = workflow.replace(body, body.replace(
                    f"runs-on: {MACOS_LABEL}\n", f"runs-on: {label}\n", 1), 1)
                self.assertNotEqual(moved, workflow)
                self.assertTrue(runner_problems(moved), label)
        full = workflow.replace("&& 'macos-15' ||", "&& 'macos-15-intel' ||", 1)
        self.assertNotEqual(full, workflow)
        self.assertTrue(runner_problems(full))

    def test_dropping_the_arm64_artifact_assertions_or_the_shard_structure_is_detected(self):
        workflow = read(".github/workflows/ci.yml")
        for needle, replacement in (
            ('          test "$(lipo -archs .build/release/LogicProMCP)" = arm64\n', ""),
            ('          test "$(lipo -archs "$test_binary")" = arm64\n', ""),
            ("      max-parallel: 2\n", ""),
            ("          - shard: complement\n            mode: skip\n", ""),
            ("needs: [change-scope, release-build, test-build, test-shards]",
             "needs: [change-scope, release-build, test-build]"),
        ):
            with self.subTest(needle=needle):
                mutant = workflow.replace(needle, replacement, 1)
                self.assertNotEqual(mutant, workflow)
                self.assertTrue(runner_problems(mutant))

    def test_the_universal_release_is_still_installed_on_both_architectures(self):
        release = read(".github/workflows/release.yml")
        self.assertEqual(re.findall(r"^        os: \[(.*)\]$", release, re.M),
                         ["macos-15-intel, macos-26", "macos-15-intel, macos-26"])


RELEASE_PATH_SCRIPTS = (
    "release.sh", "release-qualify.sh", "release-stable.sh", "release-package.sh",
    "release-fetch-qualified-inputs.sh", "release-build-universal.sh",
    "release-verify-formula-install-paths.sh", "ci-native-qualify.sh",
)
BASH32 = "/bin/bash"
# Constructs that fail on the macOS stock bash 3.2 (or, for a bare array
# expansion, only when the array is empty under `set -u`).
BASH4_ONLY = (
    (r'(?<!\+)"\$\{\w+\[[@*]\]\}"', "bare array expansion (unbound when empty under set -u)"),
    (r"(?<!\+)(?<![\"\w])\$\{\w+\[[@*]\]\}", "unquoted bare array expansion"),
    (r"\bdeclare\s+-[a-zA-Z]*A", "declare -A"),
    (r"\b(mapfile|readarray)\b", "mapfile/readarray"),
    (r"\$\{\w+(,,|\^\^|,|\^)\}", "case-modifying expansion"),
    (r"&>>", "&>>"),
    (r"\|&", "|&"),
    (r"\[-\d+\]", "negative array index"),
    (r"\bwait\s+-n\b", "wait -n"),
    (r"\blocal\s+-n\b|\bdeclare\s+-n\b", "namerefs"),
    (r"\$\{\w+@[QEPAa]\}", "${var@op}"),
    (r"\[\[\s+-v\s", "[[ -v ]]"),
)


class ReleaseScriptsRunOnBash32(unittest.TestCase):
    """The release path must run on /bin/bash 3.2, the macOS stock shell."""

    def test_no_construct_that_breaks_bash32(self):
        problems = []
        for name in RELEASE_PATH_SCRIPTS:
            text = read(f"Scripts/{name}")
            for number, line in enumerate(text.splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                for pattern, label in BASH4_ONLY:
                    if re.search(pattern, line):
                        problems.append(f"{name}:{number}: {label}: {line.strip()}")
        self.assertEqual(problems, [])

    def test_scripts_parse_under_stock_bash(self):
        if not os.path.exists(BASH32):
            self.skipTest("no /bin/bash")
        for name in RELEASE_PATH_SCRIPTS:
            result = subprocess.run([BASH32, "-n", os.path.join(REPO, "Scripts", name)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{name}: {result.stderr}")

    def run_fetch_candidate_evidence(self, run_attempt):
        if not os.path.exists(BASH32):
            self.skipTest("no /bin/bash")
        match = re.search(r"^fetch_candidate_evidence\(\) \{\n.*?^\}\n",
                          read("Scripts/release.sh"), re.S | re.M)
        self.assertTrue(match, "fetch_candidate_evidence not found in release.sh")
        with tempfile.TemporaryDirectory() as tmp:
            script = textwrap.dedent("""\
                set -euo pipefail
                REPO=o/r RUN_ID=1 QUALIFIED=abc RUN_ATTEMPT="$1" EVIDENCE_DIR="$2"
                gh() { echo '{"run_attempt": 1}'; }
                python3() {
                  if [ "$1" = - ]; then command python3 "$@"; else echo "$@" > "$EVIDENCE_DIR/argv"; fi
                }
                """) + match.group(0) + "fetch_candidate_evidence first\n"
            result = subprocess.run([BASH32, "-c", script, "bash", run_attempt, tmp],
                                    cwd=REPO, text=True, capture_output=True)
            argv = pathlib.Path(tmp, "argv").read_text() if pathlib.Path(tmp, "argv").exists() else ""
            return result, argv

    def test_fetch_candidate_evidence_with_empty_run_attempt(self):
        result, argv = self.run_fetch_candidate_evidence("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--expected-attempt", argv)

    def test_fetch_candidate_evidence_with_run_attempt(self):
        result, argv = self.run_fetch_candidate_evidence("2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--expected-attempt 2", argv)


if __name__ == "__main__":
    unittest.main(verbosity=2)
