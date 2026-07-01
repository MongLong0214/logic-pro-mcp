import Foundation
import Testing
@testable import LogicProMCP

@Suite("native event backend regression", .serialized)
struct NativeEventBackendRegressionTests {
    @Test("removed external click binary name stays out of critical source surfaces")
    func removedExternalClickBinaryNameStaysOutOfCriticalSources() throws {
        let forbidden = "cli" + "click"
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Sources/LogicProMCP/Projects/ProjectExportExecutorBounceHelper.swift",
            "Sources/LogicProMCP/Projects/ProjectExportExecutorBounceHelperResolution.swift",
            "Sources/LogicProMCP/Utilities/SetupDoctor.swift",
            "Sources/LogicProMCP/Dispatchers/SystemDispatcher.swift",
            "Scripts/logic_bounce.py",
            "Scripts/logic_bounce_ui.py",
        ]

        for path in paths {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.localizedCaseInsensitiveContains(forbidden), "\(path) reintroduced removed tool name")
        }
    }
}
