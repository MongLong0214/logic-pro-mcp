import Foundation
import Testing

@Test func release_script_contains_main_branch_and_test_gates() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("git branch --show-current"))
    #expect(script.contains("!= main"))
    #expect(script.contains("stable releases must be tagged from the main branch"))
    #expect(script.contains("git fetch --quiet origin main --tags"))
    #expect(script.contains("git rev-parse HEAD"))
    #expect(script.contains("git rev-parse origin/main"))
    #expect(script.contains("HEAD must match origin/main"))
    #expect(script.contains("bash Scripts/release-consume-final.sh stage"))
    #expect(!script.contains("swift build"))
    #expect(!script.contains("gh release create"))

    let branchGate = try #require(script.range(of: "git branch --show-current"))
    let headGate = try #require(script.range(of: "git rev-parse HEAD"))
    let consumption = try #require(script.range(of: "bash Scripts/release-consume-final.sh stage"))
    let pins = try #require(script.range(of: "BINARY_SHA=$(shasum"))
    let tag = try #require(script.range(of: "git tag \"$VERSION\""))
    let tagPush = try #require(script.range(of: "git push origin \"$VERSION\""))
    #expect(branchGate.lowerBound < tagPush.lowerBound)
    #expect(headGate.lowerBound < tagPush.lowerBound)
    #expect(consumption.lowerBound < pins.lowerBound)
    #expect(pins.lowerBound < tag.lowerBound)
    #expect(tag.lowerBound < tagPush.lowerBound)
}

@Test func release_qualification_gate_builds_and_requires_live_logic_before_full_suite() throws {
    let gate = try scriptContents("Scripts/release-qualify.sh")

    let build = try #require(gate.range(of: "\nswift build -c release\n"))
    let logic = try #require(gate.range(of: "if ! pgrep -xq \"Logic Pro\"; then"))
    let permission = try #require(gate.range(of: "if ! .build/release/LogicProMCP --check-permissions; then"))
    let suite = try #require(gate.range(of: "\nswift test --no-parallel\n"))
    #expect(build.lowerBound < logic.lowerBound)
    #expect(logic.lowerBound < permission.lowerBound)
    #expect(permission.lowerBound < suite.lowerBound)
}

@Test func release_workflow_runs_tests_before_packaging() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")

    let selectXcode = try #require(workflow.range(of: "name: Select Xcode"))
    // The candidate is already final and qualified. Only the independently
    // pinned verifier is built; consumer behavior is exercised separately.
    let resolve = try #require(workflow.range(of: "swift package resolve --force-resolved-versions"))
    let buildVerifier = try #require(workflow.range(of: "swift build -c release --product trusted-verifier --force-resolved-versions"))
    let package = try #require(workflow.range(of: "name: Package"))

    #expect(selectXcode.lowerBound < resolve.lowerBound)
    #expect(resolve.lowerBound < buildVerifier.lowerBound)
    #expect(buildVerifier.lowerBound < package.lowerBound)
    #expect(!workflow.contains("name: Build universal binary"))
    #expect(!workflow.contains("codesign --force"))
}

@Test func ci_workflow_gates_package_resolved_drift() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")

    #expect(workflow.contains("git diff --exit-code Package.resolved"))
    let build = try #require(workflow.range(of: "name: Build"))
    let lockfileGate = try #require(workflow.range(of: "git diff --exit-code Package.resolved"))
    // The step was `Coverage report` until 2026-09-18, when running the tests and deciding on the
    // numbers became two steps and the decision moved to `Scripts/ci-coverage-gate.sh`. Searching
    // for the old name failed this case loudly, which is right -- a step this test orders against
    // must be a step that exists. The claim is unchanged: the lockfile gate runs after the build
    // and before anything measures coverage.
    let coverage = try #require(workflow.range(of: "name: Run the tests and collect coverage"))
    let coverageGate = try #require(workflow.range(of: "name: Coverage gate"))
    #expect(build.lowerBound < lockfileGate.lowerBound)
    #expect(lockfileGate.lowerBound < coverage.lowerBound)
    #expect(coverage.lowerBound < coverageGate.lowerBound,
            "the tests must run before the gate reads the profile they produced")
}
