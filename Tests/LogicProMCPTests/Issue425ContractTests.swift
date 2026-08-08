import Foundation
import Testing

@Suite("#425 shipped-design contract")
struct Issue425ContractTests {
    private static let inertFlagTokens = [
        "insertCoordFree",
        "LOGIC_MCP_INSERT_COORD_FREE",
    ]

    private static func sourceTexts() throws -> [(url: URL, text: String)] {
        let sources = installScriptContractRepositoryRootURL().appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        )

        var texts: [(url: URL, text: String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            texts.append((url, try String(contentsOf: url, encoding: .utf8)))
        }
        return texts
    }

    @Test("#425 flag is absent from Sources or has a production consumer")
    func insertCoordinateFreeFlagIsNotInert() throws {
        let sources = try Self.sourceTexts()
        let featureFlagsURL = installScriptContractRepositoryRootURL()
            .appendingPathComponent("Sources/LogicProMCP/Utilities/FeatureFlags.swift")
            .standardizedFileURL

        let flagExists = sources.contains { source in
            Self.inertFlagTokens.contains { source.text.contains($0) }
        }
        let productionConsumerCount = sources
            .filter { $0.url.standardizedFileURL != featureFlagsURL }
            .reduce(0) { count, source in
                count + Self.inertFlagTokens.reduce(0) { tokenCount, token in
                    tokenCount + source.text.components(separatedBy: token).count - 1
                }
            }

        #expect(
            !flagExists || productionConsumerCount > 0,
            "#425 insert-coordinate-free flag exists in Sources but has no production consumer outside FeatureFlags.swift"
        )
    }

    @Test("#425 ticket documents the shipped custom-action and AXPick design")
    func ticketMatchesShippedDesign() throws {
        let ticket = try scriptContents("docs/tickets/issue-425-coord-free-insert.md")

        #expect(!ticket.contains("Slot-open stays a coordinate click."))
        #expect(!ticket.contains("LOGIC_MCP_INSERT_COORD_FREE"))
        #expect(ticket.contains("slot-open uses the exact custom action"))
        #expect(ticket.contains("`AXPick` for category and leaf selection"))
    }
}
