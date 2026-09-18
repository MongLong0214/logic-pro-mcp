import Foundation
import Testing
@testable import LogicProMCP

/// #908: Logic 11 is not supported, decided 2026-09-18.
///
/// The decision had ALREADY been made in code and nobody had connected it to the question.
/// `LogicProSupport.minimumSupportedLogicVersion` has been `12.0.1` and `logic.version_support`
/// has failed below it — while `AXLogicProElements+Markers.swift` carried a note saying the
/// support question was open, and the roadmap row said the same. The floor was enforced and
/// undeclared; the issue was declared and unenforced.
///
/// What was missing either way is this: the floor had never been watched REFUSING anything. No
/// case fed it a Logic 11 version, so "we support 12.0.1 and up" was a constant with a comparison
/// beside it and no evidence that the comparison decides anything.
@Suite("Issue908 the Logic version floor")
struct Issue908LogicVersionFloorTests {

    /// The dependency the check refuses without. `logic.version_support` is `.skipped` unless
    /// `logic.installation` has PASSED -- it will not judge a version it was not told is readable,
    /// which is why the first version of these cases got `.skipped` for every Logic 11 and proved
    /// nothing.
    static let installed = SetupDoctor.check(
        id: "logic.installation",
        domain: "logic",
        status: .pass,
        summary: "Logic Pro is installed and readable.",
        evidence: [:],
        remediationType: .none
    )

    static func app(_ version: String) -> SetupDoctor.LogicAppInfo {
        SetupDoctor.LogicAppInfo(
            path: "/Applications/Logic Pro.app",
            version: version,
            bundleID: ServerConfig.logicProBundleID,
            readable: true
        )
    }

    /// The floor is at least 12, so "support Logic 11" cannot come back by lowering a constant
    /// without this case going red.
    @Test("the supported floor is a Logic 12")
    func theFloorIsTwelve() {
        let floor = LogicProSupport.minimumSupportedLogicVersion
        #expect(SetupDoctor.compareVersions(floor, "12.0") >= 0,
                "the floor is \(floor); #908 decided Logic 11 is not supported")
        #expect(SetupDoctor.compareVersions(LogicProSupport.latestValidatedLogicVersion, floor) >= 0,
                "the latest validated version cannot be below the floor")
    }

    /// Every Logic 11 a user might have, refused by the check a user actually runs.
    @Test("a Logic 11 install fails logic.version_support",
          arguments: ["11.0", "11.1", "11.1.2", "11.2", "11.9.9"])
    func logicElevenFails(version: String) {
        let result = SetupDoctor.logicVersionSupportCheck(logicApps: [Self.app(version)], checks: [Self.installed])
        #expect(result.status == .fail, "\(version) produced \(result.status)")
        #expect(result.summary.contains(version))
        #expect(result.evidence["minimum_supported"] == LogicProSupport.minimumSupportedLogicVersion)
    }

    /// The floor itself passes, so the case above is about Logic 11 and not about the comparison
    /// refusing everything.
    @Test("the floor version and the validated version are accepted",
          arguments: [LogicProSupport.minimumSupportedLogicVersion,
                      LogicProSupport.latestValidatedLogicVersion])
    func supportedVersionsAreAccepted(version: String) {
        let result = SetupDoctor.logicVersionSupportCheck(logicApps: [Self.app(version)], checks: [Self.installed])
        #expect(result.status != .fail, "\(version) produced \(result.status)")
    }
}
