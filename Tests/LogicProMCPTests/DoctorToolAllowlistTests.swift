import Foundation
import Testing
@testable import LogicProMCP

// MARK: - T1 (doctor-v3): D10 structural guard — DoctorTool allowlist + source-grep lint

private func doctorRepositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func readDoctorRepoFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: doctorRepositoryRootURL().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func doctorSourceFilesForProcessLint() throws -> [(String, String)] {
    let utilities = doctorRepositoryRootURL()
        .appendingPathComponent("Sources/LogicProMCP/Utilities", isDirectory: true)
    let names = try FileManager.default.contentsOfDirectory(atPath: utilities.path)
        .filter { name in
            (name.hasPrefix("SetupDoctor") && name.hasSuffix(".swift")) || name == "DoctorTool.swift"
        }
        .sorted()
    return try names.map { name in
        let source = try String(contentsOf: utilities.appendingPathComponent(name), encoding: .utf8)
        return (name, source)
    }
}

// Case 11
@Test func test_t1v3_doctor_tool_allowlist_rejects_arbitrary_binary() {
    // AC-6 fail-closed. `/bin/echo` EXISTS but is NOT allowlisted → the production
    // runCommand must return nil WITHOUT spawning it (side-effect-free proof).
    // TR1: never pass a real LogicProMCP path here — only /bin/echo + a nonexistent path.
    #expect(SetupDoctor.Runtime.production.runCommand("/bin/echo", ["harmless"]) == nil)
    #expect(SetupDoctor.Runtime.production.runCommand("/tmp/nonexistent-doctor-tool", []) == nil)
}

// Case 12
@Test func test_t1v3_doctor_tool_allowlist_accepts_known_tools() throws {
    // AC-6: BOTH brew prefixes resolve (else install.source regresses), plus a /usr/bin tool.
    #expect(try #require(DoctorTool.resolve("/opt/homebrew/bin/brew")) == .brew)
    #expect(try #require(DoctorTool.resolve("/usr/local/bin/brew")) == .brew)
    #expect(try #require(DoctorTool.resolve("/usr/bin/codesign")) == .codesign)
}

// Case 13
@Test func test_t1v3_lint_no_raw_process_outside_bounded_runner() throws {
    let offending = try doctorSourceFilesForProcessLint().flatMap { name, source in
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.contains("Process(") || $0.element.contains("posix_spawn") }
            .map { "\(name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
    }
    #expect(offending.isEmpty, "raw process spawn outside BoundedProcessRunner: \(offending)")
}
