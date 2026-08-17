import Testing
@testable import LogicProMCP

/// `RegionInventoryPayload.complete` used to be hardcoded `false` on every successful read.
///
/// Safe, but uninformative — and it made every consumer fail closed forever, which is why
/// `midi.import_file` could not tell "no region" from "no region visible" (#576).
///
/// It is now derived from the track headers, not from the regions. That distinction is the whole
/// point: a track carrying no regions produces no entry, so the highest observed `trackIndex` says
/// nothing about the tracks above it. Measured on Logic 12.3, 2026-08-17: `allTrackHeaders` returned
/// 21 while the region layer stopped at 13, so the header list is the denominator a completeness
/// claim needs.
///
/// Live, on the same project, driving the arrange window's `Vertical Zoom` slider:
///
///     zoom 0.6   complete false   headers 21   in-viewport 6    regions 6
///     zoom 0.0   complete true    headers 21   in-viewport 21   regions 20
///
/// The second row also shows why regions cannot be the denominator: 21 tracks were visible and only
/// 20 carried a region.
@Suite("#576 completeness is measured against the header list")
struct Issue576MeasuredCompletenessTests {
    private func result(headers: Int, inViewport: Int) -> AccessibilityChannel.RegionEnumerationResult {
        AccessibilityChannel.RegionEnumerationResult(
            regions: [],
            layoutItemCount: 0,
            nonRegionCount: 0,
            trackHeaderCount: headers,
            trackHeadersWithinViewport: inViewport
        )
    }

    @Test("every header inside the viewport means the enumeration saw every track")
    func fullCoverageIsComplete() {
        #expect(result(headers: 21, inViewport: 21).coversEveryTrack)
        #expect(result(headers: 1, inViewport: 1).coversEveryTrack)
    }

    @Test("a header outside the viewport means it did not")
    func partialCoverageIsNotComplete() {
        // The live 0.6-zoom reading.
        #expect(!result(headers: 21, inViewport: 6).coversEveryTrack)
        // One short is still short: the missing track is exactly where an unseen region would be.
        #expect(!result(headers: 21, inViewport: 20).coversEveryTrack)
    }

    /// Zero headers is the case that decides whether this is a completeness claim or a vacuous one.
    /// With nothing to bound the claim there is nothing to have covered, and `0 == 0` would make an
    /// unreadable arrangement report as exhaustively read — an absence published as proof, which is
    /// the defect #576 exists to remove.
    @Test("no headers at all is not completeness")
    func zeroHeadersIsNotComplete() {
        #expect(!result(headers: 0, inViewport: 0).coversEveryTrack)
    }
}
