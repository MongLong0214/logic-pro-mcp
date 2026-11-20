import Foundation
import Testing
@testable import LogicProMCP

/// v3.19.0 is qualified on Logic Pro 13.0 (build 7801), the version docs/canon/MANIFEST.json
/// pins. The doctor must call that version the latest validated one; before this suite it
/// still named 12.3 and would have told every Logic 13 user their version was outside it.
@Suite("The latest validated Logic version is the qualified one")
struct LatestValidatedLogicVersionTests {

    @Test("a Logic Pro 13.0 install passes logic.version_support as the latest validated version")
    func logicThirteenIsLatest() {
        let result = SetupDoctor.logicVersionSupportCheck(
            logicApps: [Issue908LogicVersionFloorTests.app("13.0")],
            checks: [Issue908LogicVersionFloorTests.installed]
        )
        #expect(result.status == .pass, "13.0 produced \(result.status): \(result.summary)")
        #expect(result.summary.contains("matches the latest validated version"))
    }

    @Test("the constant equals the version the canon MANIFEST pins")
    func constantMatchesCanonManifest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/canon/MANIFEST.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let logic = try #require(json["logic"] as? [String: Any])
        let pinned = try #require(logic["version"] as? String)
        #expect(LogicProSupport.latestValidatedLogicVersion == pinned,
                "the canon MANIFEST pins Logic \(pinned)")
    }

    @Test("the latest validated version is derived from the one Logic declaration")
    func derivedFromTheOneDeclaration() {
        #expect(LogicProSupport.latestValidatedLogicVersion == AXLocalePolicy.currentLogicVersion)
    }

    @Test("manifest.json's latest_logic_pro_version equals the one declaration")
    func manifestMatchesTheDeclaration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["latest_logic_pro_version"] as? String == AXLocalePolicy.currentLogicVersion)
    }

    @Test("the previous latest, 12.3, is now a supported-but-not-latest warning")
    func twelveThreeWarns() {
        let result = SetupDoctor.logicVersionSupportCheck(
            logicApps: [Issue908LogicVersionFloorTests.app("12.3")],
            checks: [Issue908LogicVersionFloorTests.installed]
        )
        #expect(result.status == .warn)
    }
}
