import Foundation
import Testing

private func parityRepositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func sourceString(at relativePath: String) throws -> String {
    let url = parityRepositoryRootURL().appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func stringLiteral(after marker: String, in source: String) throws -> String {
    let markerRange = try #require(source.range(of: marker))
    let tail = source[markerRange.upperBound...]
    let start = try #require(tail.firstIndex(of: "\""))
    let remainder = tail[tail.index(after: start)...]
    let end = try #require(remainder.firstIndex(of: "\""))
    return String(tail[start...end])
}

private func arrayLiteral(after marker: String, in source: String) throws -> String {
    let markerRange = try #require(source.range(of: marker))
    let tail = source[markerRange.upperBound...]
    let start = try #require(tail.firstIndex(of: "["))
    let remainder = tail[tail.index(after: start)...]
    let end = try #require(remainder.firstIndex(of: "]"))
    return String(tail[start...end])
}

@Test func appleScriptClassifierParityWithRegionDragSpikeSource() throws {
    let classifier = try sourceString(at: "Sources/LogicProMCP/Utilities/AppleScriptErrorClassifier.swift")
    let spike = try sourceString(at: "Scripts/spike-midi-region-drag-export.swift")

    let classifierHint = try stringLiteral(
        after: "systemEventsAutomationDeniedHint =",
        in: classifier
    )
    let spikeTerminalNote = try stringLiteral(
        after: "systemEventsAutomationDeniedTerminalNote =",
        in: spike
    )
    #expect(classifierHint == spikeTerminalNote)

    let classifierCoreTokens = try arrayLiteral(
        after: "systemEventsAutomationDeniedCoreMatchTokens =",
        in: classifier
    )
    let spikeCoreTokens = try arrayLiteral(
        after: "systemEventsAutomationDeniedCoreMatchTokens =",
        in: spike
    )
    #expect(classifierCoreTokens == spikeCoreTokens)
}
