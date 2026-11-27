import Foundation
import Testing

/// Hosted CI has no Logic, so a test that switches on only where Logic is installed is reported as
/// skipped there, and `verify-xunit` counts a skip as run. Such a test executes nowhere unless the
/// Logic host runs it. These tests derive the set of gated tests from the sources and fail when the
/// host run in `Scripts/release-qualify.sh` does not cover exactly the host-gated ones, or when a
/// new condition is written that no class below accounts for.
private struct GatedAttribute {
    let file: String
    let function: String?
    let text: String
}

private enum GateClass: String {
    /// Needs Logic installed (app, Library, factory-settings roots). Marked, run on the Logic host.
    case logicHost
    /// Needs LOGIC_PRO_MCP_RUN_LIVE_QA and drives Logic; named in the live loops of the script.
    case liveQualification
    /// Needs a binary this build produced; present on every lane that builds the package.
    case builtBinary
    /// Needs an operator-supplied native project; not run by any automated lane.
    case operatorNative
}

private func classify(_ attribute: GatedAttribute) -> GateClass? {
    let text = attribute.text
    if text.contains(".requiresLogicHost(") { return .logicHost }
    // A host condition spelled any other way is not a build-artifact or live gate, whatever else
    // the attribute mentions.
    let hostWords = ["installed", "/Applications", "NSHomeDirectory", "homeDirectory", "Logic Pro.app", "/Library/"]
    if hostWords.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) { return nil }
    if text.contains("LOGIC_PRO_MCP_RUN_LIVE_QA") { return .liveQualification }
    if text.contains("LOGIC_MCP_NATIVE_") { return .operatorNative }
    if text.contains("isExecutableFile") || text.contains("driveEnabled") { return .builtBinary }
    return nil
}

/// The text inside the parentheses that open at `open`, skipping string literals.
private func balancedParentheses(in characters: [Character], from open: Int) -> (text: String, end: Int)? {
    var depth = 0
    var index = open
    var inString = false
    while index < characters.count {
        let character = characters[index]
        if inString {
            if character == "\\" { index += 1 } else if character == "\"" { inString = false }
        } else if character == "\"" {
            inString = true
        } else if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 { return (String(characters[(open + 1)..<index]), index) }
        }
        index += 1
    }
    return nil
}

private func testSources() throws -> [(file: String, text: String)] {
    let root = installScriptContractRepositoryRootURL().appendingPathComponent("Tests/LogicProMCPTests")
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return try enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
        .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
}

/// Every `@Test(...)` and `@Suite(...)` attribute that carries a runtime condition.
private func gatedAttributes() throws -> [GatedAttribute] {
    var found: [GatedAttribute] = []
    for (file, source) in try testSources() {
        let lines = source.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@Test(") || trimmed.hasPrefix("@Suite(") else { continue }
            let rest = lines[lineIndex...].joined(separator: "\n")
            let characters = Array(rest)
            guard let open = characters.firstIndex(of: "("),
                  let attribute = balancedParentheses(in: characters, from: open) else { continue }
            guard attribute.text.contains(".enabled(") || attribute.text.contains(".disabled(")
                    || attribute.text.contains(".requiresLogicHost(") else { continue }
            var function: String?
            if trimmed.hasPrefix("@Test(") {
                let after = String(characters[(attribute.end + 1)...].prefix(600))
                if let match = after.range(of: #"func\s+(\w+)"#, options: .regularExpression) {
                    function = String(after[match]).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).last
                        .map(String.init)
                }
            }
            found.append(GatedAttribute(file: file, function: function, text: attribute.text))
        }
    }
    return found
}

private func scriptList(_ name: String, in script: String) throws -> Set<String> {
    let opening = try #require(script.range(of: "\(name)=(\n"))
    let closing = try #require(script.range(of: "\n)\n", range: opening.upperBound..<script.endIndex))
    let body = String(script[opening.upperBound..<closing.lowerBound])
    return Set(body.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    })
}

@Test func theLogicHostRunsExactlyTheTestsMarkedAsNeedingLogic() throws {
    let marked = Set(try gatedAttributes().filter { classify($0) == .logicHost }.compactMap(\.function))
    let script = try scriptContents("Scripts/release-qualify.sh")
    let listed = try scriptList("host_gated_tests", in: script)
    #expect(!marked.isEmpty, "no `.requiresLogicHost` test found: the scan is not reading the sources")
    #expect(marked == listed,
            "host_gated_tests in Scripts/release-qualify.sh differs from the `.requiresLogicHost` tests; missing=\(marked.subtracting(listed).sorted()) extra=\(listed.subtracting(marked).sorted())")
}

@Test func everyConditionOnATestBelongsToAClassWithALaneThatRunsIt() throws {
    let gated = try gatedAttributes()
    let unclassified = gated.filter { classify($0) == nil }
    #expect(unclassified.isEmpty,
            "a test condition no lane accounts for: write a Logic-install condition with `.requiresLogicHost(if:)` and add the test to host_gated_tests; \(unclassified.map { "\($0.file): \($0.function ?? "suite")" })")

    // Every live-qualification test is named in a live loop of the script, which sets the flag.
    let script = try scriptContents("Scripts/release-qualify.sh")
    let live = try scriptList("release_live_tests", in: script).union(scriptList("debug_live_tests", in: script))
    let liveGated = Set(gated.filter { classify($0) == .liveQualification }.compactMap(\.function))
    #expect(!liveGated.isEmpty)
    #expect(liveGated.isSubset(of: live), "a live test no loop runs: \(liveGated.subtracting(live).sorted())")

    // The only ConditionTrait values declared outside an attribute are the two sandbox traits,
    // which switch a test off only inside a restricted sandbox, never on the Logic host.
    let declared = try testSources().filter { $0.file != "HostGatedTestsContractTests.swift" }.flatMap { file, text in
        text.components(separatedBy: "\n")
            .filter { $0.contains(": ConditionTrait") }
            .map { "\(file): \($0.trimmingCharacters(in: .whitespaces))" }
    }
    #expect(declared.count == 2 && declared.allSatisfy {
        $0.contains("processInspectionUnavailableInSandbox") || $0.contains("coreMIDIUnavailableInSandbox")
    }, "a new shared ConditionTrait needs a lane that runs what it gates: \(declared)")
}

@Test func theHostRunFollowsTheLiveTestsAndFailsUnlessEveryHostTestPassed() throws {
    let script = try scriptContents("Scripts/release-qualify.sh")
    let debugLoop = try #require(script.range(of: "for live_test in ${debug_live_tests[@]+\"${debug_live_tests[@]}\"}; do"))
    let hostRun = try #require(script.range(of: "swift test --no-parallel ${host_gated_filters[@]+\"${host_gated_filters[@]}\"}",
                                            range: debugLoop.upperBound..<script.endIndex))
    let finalCheck = try #require(script.range(of: "verify_candidate_bytes\ntrap - EXIT INT TERM",
                                               range: hostRun.upperBound..<script.endIndex))
    #expect(hostRun.lowerBound < finalCheck.lowerBound)
    #expect(script.contains("[ \"$host_gated_passed\" -ne \"${#host_gated_tests[@]}\" ]"),
            "the host run must fail unless every listed test passed")
    #expect(!script.contains("LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel ${host_gated"),
            "host-gated tests need Logic installed, not driven")
    #expect(!script.contains("hosted CI runs every test of the same\n# candidate (the union of every test-shards shard), and only"),
            "the false claim that hosted CI runs every test must not return")
}
