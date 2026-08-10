import Foundation
import Testing

@Test func release_script_contains_main_branch_and_test_gates() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("git branch --show-current"))
    #expect(script.contains("\"main\""))
    #expect(script.contains("stable releases must be tagged from the main branch"))
    #expect(script.contains("git fetch --quiet origin main --tags"))
    #expect(script.contains("git rev-parse HEAD"))
    #expect(script.contains("git rev-parse origin/main"))
    #expect(script.contains("HEAD must match origin/main"))
    #expect(script.contains("swift test --no-parallel"))
    #expect(script.contains("git diff --exit-code Package.resolved"))

    let branchGate = try #require(script.range(of: "git branch --show-current"))
    let headGate = try #require(script.range(of: "git rev-parse HEAD"))
    let testGate = try #require(script.range(of: "swift test --no-parallel"))
    let lockfileGate = try #require(script.range(of: "git diff --exit-code Package.resolved"))
    let tagPush = try #require(script.range(of: "git push origin $VERSION"))
    #expect(branchGate.lowerBound < tagPush.lowerBound)
    #expect(headGate.lowerBound < tagPush.lowerBound)
    #expect(testGate.lowerBound < tagPush.lowerBound)
    #expect(lockfileGate.lowerBound < tagPush.lowerBound)
}

@Test func release_workflow_runs_tests_before_packaging() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")

    let selectXcode = try #require(workflow.range(of: "name: Select Xcode"))
    let testStep = try #require(workflow.range(of: "swift test --no-parallel"))
    let buildUniversal = try #require(workflow.range(of: "name: Build universal binary"))
    let package = try #require(workflow.range(of: "name: Package"))

    #expect(selectXcode.lowerBound < testStep.lowerBound)
    #expect(testStep.lowerBound < buildUniversal.lowerBound)
    #expect(testStep.lowerBound < package.lowerBound)
}

@Test func ci_workflow_gates_package_resolved_drift() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")

    #expect(workflow.contains("git diff --exit-code Package.resolved"))
    let build = try #require(workflow.range(of: "name: Build"))
    let lockfileGate = try #require(workflow.range(of: "git diff --exit-code Package.resolved"))
    let coverage = try #require(workflow.range(of: "name: Coverage report"))
    #expect(build.lowerBound < lockfileGate.lowerBound)
    #expect(lockfileGate.lowerBound < coverage.lowerBound)
}
