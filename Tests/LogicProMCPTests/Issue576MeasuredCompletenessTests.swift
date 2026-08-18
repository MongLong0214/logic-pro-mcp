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
    private func result(
        headers: Int,
        inViewport: Int,
        droppedRegions: Int = 0
    ) -> AccessibilityChannel.RegionEnumerationResult {
        AccessibilityChannel.RegionEnumerationResult(
            regions: [],
            layoutItemCount: 0,
            nonRegionCount: 0,
            trackHeaderCount: headers,
            trackHeadersWithinViewport: inViewport,
            regionItemsOutsideViewport: droppedRegions
        )
    }

    @Test("every header inside the viewport means the enumeration saw every track")
    func fullCoverageIsComplete() {
        #expect(result(headers: 21, inViewport: 21).coversWholeArrangement)
        #expect(result(headers: 1, inViewport: 1).coversWholeArrangement)
    }

    @Test("a header outside the viewport means it did not")
    func partialCoverageIsNotComplete() {
        // The live 0.6-zoom reading.
        #expect(!result(headers: 21, inViewport: 6).coversWholeArrangement)
        // One short is still short: the missing track is exactly where an unseen region would be.
        #expect(!result(headers: 21, inViewport: 20).coversWholeArrangement)
    }

    /// The headers are the VERTICAL axis only. A region at bar 33 sits far to the right of a window
    /// whose every track header is visible, so header coverage alone is not completeness — the first
    /// version of this rule checked only the headers, and
    /// `testAccessibilityChannelAXBackedRegionsMarkViewportSubsetIncomplete` (which models exactly
    /// that arrangement) caught it before it shipped.
    @Test("a region dropped for lying outside the window is incompleteness too")
    func droppedRegionIsNotComplete() {
        #expect(!result(headers: 2, inViewport: 2, droppedRegions: 1).coversWholeArrangement)
        #expect(result(headers: 2, inViewport: 2, droppedRegions: 0).coversWholeArrangement)
    }

    /// Zero headers is the case that decides whether this is a completeness claim or a vacuous one.
    /// With nothing to bound the claim there is nothing to have covered, and `0 == 0` would make an
    /// unreadable arrangement report as exhaustively read — an absence published as proof, which is
    /// the defect #576 exists to remove.
    @Test("no headers at all is not completeness")
    func zeroHeadersIsNotComplete() {
        #expect(!result(headers: 0, inViewport: 0).coversWholeArrangement)
    }
}

/// `RegionInventoryPayload.isComplete` decides what the CACHE records, and it used to default to
/// `true` when the payload said nothing about its own coverage.
///
/// That was harmless while `complete` was a hardcoded `false` every producer set. It stopped being
/// harmless the moment completeness began deciding whether an absent region is evidence: a payload
/// from a producer that has not been taught to report coverage — legacy, malformed, decoded from an
/// older wire — would mark the cache exhaustively read. Found by an adversarial review of the design
/// that would have consumed it.
@Suite("#576 an absent completeness claim is not a completeness claim")
struct Issue576AbsentCompletenessTests {
    private func payload(complete: Bool?) -> RegionInventoryPayload {
        RegionInventoryPayload(
            regions: [],
            complete: complete,
            scope: nil,
            reason: nil,
            returnedCount: 0,
            debug: nil
        )
    }

    @Test("silence is not coverage")
    func absentIsNotComplete() {
        #expect(!payload(complete: nil).isComplete)
    }

    @Test("an explicit claim is still honoured in both directions")
    func explicitClaimsSurvive() {
        #expect(payload(complete: true).isComplete)
        #expect(!payload(complete: false).isComplete)
    }
}

/// The legacy wire shape — a bare JSON array of regions, with no envelope around it.
///
/// `decodeInventoryPayload` synthesised `complete: true, scope: "project"` for it. That is the same
/// fail-open as the `isComplete` default, one layer down and hardcoded, so closing the default alone
/// left this path still asserting a whole-project inventory for input that claimed nothing.
///
/// An adversarial review found it by asking the question the commit could not answer both ways: if
/// legacy input is unreachable the default flip is dead code, and if it is reachable the flip missed
/// the path that still fail-opens. It was the second.
@Suite("#576 the legacy array shape claims no coverage")
struct Issue576LegacyArrayPayloadTests {
    @Test("a bare array is not a complete inventory")
    func bareArrayIsNotComplete() throws {
        let payload = try RegionInfo.decodeInventoryPayload("""
        [{"name":"MIDI Region","trackIndex":0,"startBar":1,"endBar":2,"kind":"midi"}]
        """)
        #expect(payload.regions.count == 1)
        #expect(!payload.isComplete)
        // And it does not invent a scope it was never told.
        #expect(payload.scope == nil)
        #expect(payload.reason == "legacy_array_payload_declares_no_scope")
    }

    @Test("an enveloped payload still carries its own claim")
    func envelopedPayloadKeepsItsClaim() throws {
        let complete = try RegionInfo.decodeInventoryPayload("""
        {"regions":[],"complete":true,"scope":"whole_arrangement","returned_count":0}
        """)
        #expect(complete.isComplete)
        #expect(complete.scope == "whole_arrangement")

        let partial = try RegionInfo.decodeInventoryPayload("""
        {"regions":[],"complete":false,"scope":"visible_arrange_area","returned_count":0}
        """)
        #expect(!partial.isComplete)
    }
}
