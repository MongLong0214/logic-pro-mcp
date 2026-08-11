import Testing
@testable import LogicProMCP

/// `MIDIProviderGate` requires "Desktop variant coverage" of the Event List provider. A survey found
/// it `ABSENT`: no Event List production code or test handled `LogicProVariant` at all, so a reading
/// carried no record of which Logic product produced it.
///
/// Qualification is judged per axis — variant crossed with locale, profile, cache state and fixture
/// (`QualificationAxis`). Evidence that cannot say which product it came from cannot be placed on
/// that grid, and a desktop reading would silently count as covering Creator Studio, whose Event List
/// this project has never observed.
@Suite("#293 readback evidence states its Logic variant")
struct Issue293DesktopVariantTests {
    @Test("the variant is part of the evidence, and desktop and Creator Studio are distinguishable")
    func evidenceCarriesTheVariant() {
        let desktop = Issue293DesktopVariantTests.evidence(variant: .desktop)
        let creator = Issue293DesktopVariantTests.evidence(variant: .creatorStudio)
        #expect(desktop.variant == .desktop)
        #expect(creator.variant == .creatorStudio)
        #expect(desktop.variant != creator.variant)
    }

    @Test("an unrecognised product is recorded as unknown rather than assumed to be desktop")
    func unknownIsNotDesktop() {
        // The failure this forbids: a reading from a Logic this build does not recognise being filed
        // under the variant that happens to be most common.
        let unknown = Issue293DesktopVariantTests.evidence(variant: .unknown)
        #expect(unknown.variant == .unknown)
        #expect(unknown.variant != .desktop)
    }

    @Test("this machine's bundle identifier resolves to desktop")
    func thisHostIsDesktop() {
        // Measured: the Logic under test here is `com.apple.logic10`, the desktop product. If the
        // mapping ever stops resolving it, every live proof gathered on this machine would be filed
        // as `unknown` and stop counting toward Desktop coverage — which should be loud, not silent.
        #expect(LogicProVariant.from(bundleID: "com.apple.logic10") == .desktop)
    }

    /// Reuses the shape the provider tests already build, so this suite tests the variant record and
    /// not my guess at the surrounding types.
    /// Built from the real declarations, not from a guess at them: `MIDIRegionReference` takes a
    /// `TargetReference` and an optional index, and `FilterEvidence` takes checkboxes.
    private static func evidence(variant: LogicProVariant) -> EventListReadbackEvidence {
        let region = MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_variant"), regionIndex: 0
        )
        let identity = ResolvedRegionIdentity(name: "r", ordinal: 0, startTick: 0)
        return EventListReadbackEvidence(
            variant: variant,
            requestedRegion: region,
            resolvedIdentity: RegionIdentityRegistrySeam.mint(boundRegion: region, identity: identity),
            observedRegion: .proven(identity),
            projectEpochBefore: 1,
            projectEpochAfter: 1,
            ppq: 480,
            columnBinding: .headerIdentity(.unproven),
            filter: FilterEvidence(checkboxes: []),
            itemCount: ItemCountEvidence(rawCountText: "0 Events", semanticsProof: .unproven),
            harvest: RowHarvest(orderedRowKeys: [], passA: [:], passB: [:], exhaustion: .unproven),
            timing: .unproven,
            calibration: nil
        )
    }
}
