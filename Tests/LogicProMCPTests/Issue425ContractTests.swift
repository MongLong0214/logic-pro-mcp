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

    private static func markdownSection(named heading: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let headingIndex = lines.firstIndex(of: heading) else { return nil }

        return lines[(headingIndex + 1)...]
            .prefix { !$0.hasPrefix("## ") }
            .joined(separator: "\n")
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

    @Test("#425 ticket documents the shipped custom-action and read-only discovery design")
    func ticketMatchesShippedDesign() throws {
        let ticket = try scriptContents("docs/tickets/issue-425-coord-free-insert.md")
        let categoryPickPattern = #"(?:`?AXPick`?[^.\n]*\bcategory\b|\bcategory\b[^.\n]*`?AXPick`?)"#
        let ticketClaimsCategoryPick = ticket.range(
            of: categoryPickPattern, options: .regularExpression
        ) != nil

        #expect(!ticket.contains("Slot-open stays a coordinate click."))
        #expect(!ticket.contains("LOGIC_MCP_INSERT_COORD_FREE"))
        #expect(ticket.contains("slot-open uses the exact custom action"))
        #expect(ticket.contains("Discovery is read-only"))
        #expect(ticket.contains("already-attached `AXMenu` child"))
        #expect(ticket.contains("performs no AX action on any non-target item"))
        #expect(ticket.contains("`AXPick` is dispatched only to the leaf"))
        #expect(!ticketClaimsCategoryPick, "#425 ticket must not claim that a category is AXPick'ed")
        #expect(ticket.contains("| Gain | 2 | 2 |"))
        #expect(ticket.contains("| Compressor | 1 | 1 |"))
        #expect(ticket.contains("| Channel EQ | 1 | 1 |"))
        #expect(ticket.contains("| Tremolo | 2 | 2 |"))
        #expect(ticket.contains("| Flanger | 2 | 2 |"))
        #expect(ticket.contains("| Amps and Pedals | 4 | 4 |"))
        #expect(ticket.contains("not lazy"))
        #expect(ticket.contains("one Logic version and locale"))
    }

    @Test("#425 changelog supersedes the removed coordinate-free control")
    func changelogSupersedesRemovedCoordinateFreeControl() throws {
        let changelog = try scriptContents("CHANGELOG.md")

        // The removal statement moves when a release is cut -- `## [Unreleased]` becomes a dated
        // heading and carries its notes with it -- so requiring the statement to sit under
        // [Unreleased] tied a permanent invariant to a transient location. It is checked against
        // the whole file instead.
        //
        // But NOT as three independent substrings. A file whose newest section says the control is
        // live again still contains both tokens, and any unrelated historical entry supplies the
        // word "removed", so a token-anywhere check passes a changelog that asserts the opposite of
        // what it is supposed to guarantee. The tokens and the removal have to be the SAME
        // statement, so the claim is read as a claim rather than as a bag of words.
        let unreleased = try #require(
            Self.markdownSection(named: "## [Unreleased]", in: changelog),
            "CHANGELOG.md must contain an ## [Unreleased] section"
        )
        #expect(
            !unreleased.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "CHANGELOG.md ## [Unreleased] must not be empty"
        )

        let hasRemovedControlToken = Self.inertFlagTokens.contains { changelog.contains($0) }
        // Per LINE, not per blank-line paragraph. This file separates adjacent list items with a
        // single newline, so splitting on "\n\n" hands back a whole bullet list as one "paragraph"
        // -- and a review reproduced acceptance of two neighbouring bullets, one saying the controls
        // remain supported and another saying an unrelated fallback was removed. One bullet is one
        // claim; that is the unit the relation has to hold within.
        let negations = ["not removed", "never removed", "no longer removed", "not been removed"]
        let statesRemoval = changelog.components(separatedBy: .newlines).contains { line in
            Self.inertFlagTokens.allSatisfy { line.contains($0) }
                && line.localizedCaseInsensitiveContains("removed")
                && !negations.contains { line.localizedCaseInsensitiveContains($0) }
        }
        let categoryPickPattern = #"(?:`?AXPick`?[^.\n]*\bcategory\b|\bcategory\b[^.\n]*`?AXPick`?)"#
        // Per line and negation-aware for the same reason as above: widening the scan to the whole
        // file also widened what a truthful sentence can trip. "The server does not AXPick any
        // category" is an accurate thing for a release note to say, and a bare regex reads it as
        // the claim it denies.
        let pickNegations = ["does not `AXPick`", "does not AXPick", "never `AXPick`", "never AXPick"]
        let claimsCategoryPick = changelog.components(separatedBy: .newlines).contains { line in
            line.range(of: categoryPickPattern, options: .regularExpression) != nil
                && !pickNegations.contains { line.localizedCaseInsensitiveContains($0) }
        }

        #expect(
            !hasRemovedControlToken || statesRemoval,
            "CHANGELOG.md names the coordinate-free insert control, so one statement must carry both tokens and say it was removed"
        )
        // Widened from [Unreleased] to the whole file: a dated section claiming a category is
        // AXPick'ed is exactly as wrong as an unreleased one claiming it.
        #expect(
            !claimsCategoryPick,
            "CHANGELOG.md must not claim that a category is AXPick'ed"
        )
    }
}
