import Foundation
import Testing

@Test func release_script_contains_main_branch_and_test_gates() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("git branch --show-current"))
    #expect(script.contains("!= main"))
    #expect(script.contains("releases must be tagged from the main branch"))
    #expect(script.contains("git fetch --quiet origin main --tags"))
    #expect(script.contains("git rev-parse HEAD"))
    #expect(script.contains("git rev-parse origin/main"))
    #expect(script.contains("HEAD must match origin/main"))
    #expect(script.contains("bash Scripts/release-qualify.sh"))
    #expect(script.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
    #expect(!script.contains("gh release create"))

    let branchGate = try #require(script.range(of: "git branch --show-current"))
    let headGate = try #require(script.range(of: "git rev-parse HEAD"))
    let qualification = try #require(script.range(of: "bash Scripts/release-qualify.sh"))
    let lockfile = try #require(script.range(of: "git diff --exit-code Package.resolved"))
    let tag = try #require(script.range(of: "git tag \"$VERSION\""))
    let tagPush = try #require(script.range(of: "git push origin \"$VERSION\""))
    #expect(branchGate.lowerBound < tagPush.lowerBound)
    #expect(headGate.lowerBound < tagPush.lowerBound)
    #expect(qualification.lowerBound < lockfile.lowerBound)
    #expect(lockfile.lowerBound < tag.lowerBound)
    #expect(tag.lowerBound < tagPush.lowerBound)
}

@Test func release_qualification_gate_isolates_live_tests_before_unfiltered_full_suite() throws {
    let gate = try scriptContents("Scripts/release-qualify.sh")

    let build = try #require(gate.range(of: "\nswift build -c release\n"))
    let logic = try #require(gate.range(of: "if ! pgrep -xq \"Logic Pro\"; then"))
    let permission = try #require(gate.range(of: "if ! .build/release/LogicProMCP --check-permissions; then"))
    let liveNames = [
        "realReleaseBinaryExecutesEveryOperationWithIndependentReadback",
        "runnerIgnoresPartialStateFaultEnvOnRealServer",
        "runnerRejectsPartialStateObservedFromRealServer",
    ]
    let inventory = try #require(gate.range(of: "test_inventory=\"$(swift test list)\""))
    let liveFilter = try #require(gate.range(
        of: "LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --filter"
    ))
    let suite = try #require(gate.range(of: "\nswift test --no-parallel\n"))
    #expect(build.lowerBound < logic.lowerBound)
    #expect(logic.lowerBound < permission.lowerBound)
    #expect(permission.lowerBound < inventory.lowerBound)
    #expect(inventory.lowerBound < liveFilter.lowerBound)
    #expect(liveFilter.lowerBound < suite.lowerBound)
    #expect(liveNames.allSatisfy { gate.contains($0) })
}

@Test func release_workflow_buildsWithCommandLineToolsBeforePackaging() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")

    let toolchain = try #require(workflow.range(of: "name: Use Command Line Tools"))
    let build = try #require(workflow.range(of: "bash Scripts/release-build-universal.sh"))
    let package = try #require(workflow.range(of: "name: Package release"))
    #expect(toolchain.lowerBound < build.lowerBound)
    #expect(build.lowerBound < package.lowerBound)
    for forbidden in ["xcode-select", "Xcode_", "codesign", "notarytool", "spctl",
                      "MACOS_CERT", "APPLE_NOTARY"] {
        #expect(!workflow.contains(forbidden), "release workflow contains \(forbidden)")
    }
}

@Test func ci_workflow_gates_package_resolved_drift() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")

    #expect(workflow.contains("git diff --exit-code Package.resolved"))
    let releaseBuild = try #require(workflow.range(of: "swift build -c release"))
    let releaseLockfileGate = try #require(workflow.range(
        of: "git diff --exit-code Package.resolved",
        range: releaseBuild.upperBound..<workflow.endIndex
    ))
    let testBuild = try #require(workflow.range(of: "swift build --build-tests --enable-code-coverage"))
    let testLockfileGate = try #require(workflow.range(
        of: "git diff --exit-code Package.resolved",
        range: testBuild.upperBound..<workflow.endIndex
    ))
    let coverage = try #require(workflow.range(of: "swift test --skip-build --enable-code-coverage"))
    let coverageGate = try #require(workflow.range(of: "bash Scripts/ci-coverage-gate.sh"))
    #expect(releaseBuild.lowerBound < releaseLockfileGate.lowerBound)
    #expect(testBuild.lowerBound < testLockfileGate.lowerBound)
    #expect(testLockfileGate.lowerBound < coverage.lowerBound)
    #expect(coverage.lowerBound < coverageGate.lowerBound,
            "the tests must run before the gate reads the profile they produced")
}

@Test func ci_and_release_use_supported_standard_intel_macos_runners() throws {
    let ci = try scriptContents(".github/workflows/ci.yml")
    let release = try scriptContents(".github/workflows/release.yml")

    #expect(ci.contains("'macos-15-intel'"))
    #expect(!ci.contains("&& 'macos-15' ||"))
    #expect(release.contains("runs-on: macos-15-intel"))
    #expect(release.contains("os: [macos-15-intel, macos-26]"))
    #expect(!release.contains("macos-14"))
    #expect(!release.contains("os: [macos-15,"))
    #expect(!release.contains("os: [macos-15-intel, macos-26-intel]"))
}

@Test func ci_documentationShortcutCannotHideSourceRenames() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")

    #expect(workflow.contains("git diff --no-renames --name-only -z"))
    #expect(workflow.contains("docs/*|*.md"))
    #expect(workflow.contains("*) mode=full"))
    #expect(workflow.contains("if [ \"$changed\" -eq 0 ]; then mode=full; fi"))
}
