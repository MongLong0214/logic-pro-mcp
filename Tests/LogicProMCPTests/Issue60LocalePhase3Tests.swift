import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #60 (Phase 3): the read-only heuristic token bags that classify which AX
/// container is the marker ruler / the transport-control bar are now centralized
/// in `AXLocalePolicy` instead of inline literals. These deterministic EN+KO
/// tests pin the token coverage so a future edit can't silently drop a locale.
/// They are read-only classifiers — no State-A success is gated on them.
@Suite("Issue60 locale phase 3 token bags")
struct Issue60LocalePhase3Tests {
    @Test("marker container keywords cover EN + KO")
    func markerKeywords() {
        let labels = AXLocalePolicy.markerContainerKeywords.labels
        #expect(labels.contains("marker"))
        #expect(labels.contains("마커"))
    }

    @Test("transport container metadata covers EN + KO")
    func transportMetadata() {
        let labels = AXLocalePolicy.transportContainerMetadata.labels
        #expect(labels.contains("transport"))
        #expect(labels.contains("control bar"))
        #expect(labels.contains("컨트롤 막대"))
    }

    @Test("transport control keywords preserve the full EN + KO + JA token set")
    func transportControlKeywords() {
        let labels = Set(AXLocalePolicy.transportContainerControlKeywords.labels)
        // The exact set the inline literal carried (order-independent).
        let expected: Set<String> = [
            "play", "stop", "record", "cycle", "loop", "metronome", "rewind", "forward",
            "재생", "녹음", "사이클", "메트로놈", "클릭",
            "再生", "録音", "サイクル", "メトロノーム", "クリック",
        ]
        #expect(labels == expected, "token set drifted: \(labels.symmetricDifference(expected))")
    }

    @Test("transport slider hint tokens cover EN + KO")
    func transportSliderHints() {
        let labels = Set(AXLocalePolicy.transportSliderHints.labels)
        let expected: Set<String> = ["tempo", "bpm", "position", "템포", "재생헤드 위치", "마디", "비트"]
        #expect(labels == expected, "token set drifted: \(labels.symmetricDifference(expected))")
    }

    @Test("containsAny matches both EN and KO control-bar metadata (classifier semantics)")
    func containsAnyEnKo() {
        // The classifier scans an already-lowercased aggregate string.
        #expect(AXLocalePolicy.transportContainerMetadata.containsAny(in: "group transport bar"))
        #expect(AXLocalePolicy.transportContainerMetadata.containsAny(in: "그룹 컨트롤 막대"))
        #expect(!AXLocalePolicy.transportContainerMetadata.containsAny(in: "mixer strip"))
    }

    @Test("every Phase 3 token bag carries at least one Korean variant")
    func everyBagHasKorean() {
        let bags: [(String, AXLocalePolicy.LabelSet)] = [
            ("markerContainerKeywords", AXLocalePolicy.markerContainerKeywords),
            ("transportContainerMetadata", AXLocalePolicy.transportContainerMetadata),
            ("transportContainerControlKeywords", AXLocalePolicy.transportContainerControlKeywords),
            ("transportSliderHints", AXLocalePolicy.transportSliderHints),
        ]
        for (name, bag) in bags {
            let hasKorean = bag.labels.contains { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
            #expect(hasKorean, "\(name) must carry a Korean variant for KO-locale coverage")
        }
    }

    // MARK: - Functional classifier coverage (drives the real AX entry points)
    //
    // The token-coverage tests above pin the bag contents; these prove the bag
    // is actually *consumed* by the read-only classifier it backs, end-to-end,
    // through a fake AX tree — in both English and Korean.

    /// `enumerateMarkers` Strategy 3 (keyword fallback) must classify a marker
    /// container by the `markerContainerKeywords` bag when no Marker-List window
    /// and no AXRuler exist. Exercises EN + KO.
    @Test("enumerateMarkers keyword-fallback classifies the marker container (EN + KO)",
          arguments: ["Marker", "마커"])
    func markerKeywordFallbackIsWired(containerLabel: String) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(8000)
        let arrange = b.element(8001)
        b.setAttribute(app, kAXWindowsAttribute as String, [arrange])
        b.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        b.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
        // Title without any Marker-List suffix → Strategy 1 skipped.
        b.setAttribute(arrange, kAXTitleAttribute as String, "Proj - Tracks")
        // No AXRuler anywhere → Strategy 2 skipped, forcing the keyword fallback.
        let markerGroup = b.element(8010)
        b.setAttribute(markerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(markerGroup, kAXDescriptionAttribute as String, containerLabel)
        let t1 = b.element(8020)
        let t2 = b.element(8021)
        b.setAttribute(t1, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(t1, kAXTitleAttribute as String, "Intro")
        b.setAttribute(t2, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(t2, kAXTitleAttribute as String, "Chorus")
        b.setChildren(markerGroup, [t1, t2])
        b.setChildren(arrange, [markerGroup])

        let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: b.makeLogicRuntime(appElement: app))
        #expect(markers.map { $0.name } == ["Intro", "Chorus"], "locale \(containerLabel)")
    }

    /// A group with no marker keyword must NOT be classified as the marker
    /// container — proves the bag discriminates rather than matching anything.
    @Test("enumerateMarkers keyword-fallback ignores a non-marker group")
    func markerKeywordFallbackDiscriminates() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(8030)
        let arrange = b.element(8031)
        b.setAttribute(app, kAXWindowsAttribute as String, [arrange])
        b.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        b.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(arrange, kAXTitleAttribute as String, "Proj - Tracks")
        let mixerGroup = b.element(8040)
        b.setAttribute(mixerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(mixerGroup, kAXDescriptionAttribute as String, "Mixer")
        let t1 = b.element(8041)
        b.setAttribute(t1, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(t1, kAXTitleAttribute as String, "Volume")
        b.setChildren(mixerGroup, [t1])
        b.setChildren(arrange, [mixerGroup])

        let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: b.makeLogicRuntime(appElement: app))
        #expect(markers.isEmpty)
    }

    /// `getTransportBar` falls through to the `looksLikeTransportContainer`
    /// classifier (no toolbar / no id="Transport" group), which must recognize
    /// the control-bar group by the `transportContainerMetadata` bag. EN + KO.
    @Test("getTransportBar classifies the control bar by metadata (EN + KO)",
          arguments: ["transport", "컨트롤 막대"])
    func transportContainerMetadataIsWired(metadataLabel: String) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(8100)
        let window = b.element(8101)
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        let group = b.element(8110)
        b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(group, kAXDescriptionAttribute as String, metadataLabel)
        b.setChildren(window, [group])

        let bar = AXLogicProElements.getTransportBar(runtime: b.makeLogicRuntime(appElement: app))
        #expect(bar == group, "locale \(metadataLabel)")
    }
}
