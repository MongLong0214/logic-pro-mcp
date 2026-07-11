import Foundation
import Testing
@testable import LogicProMCP

@Suite("SelectorAtlasTests")
struct SelectorAtlasTests {
    @Test func uniqueMatchIsMutationSafe() {
        let selector = playSelector()
        let candidates = [candidate(identifier: "play-control", role: "AXButton", title: "Play")]

        let resolution = resolve(selector, in: candidates, locale: "en")

        #expect(resolution == .exact(index: 0))
        #expect(canMutate(resolution))
    }

    @Test func duplicateMatchesFailClosedWithoutChoosingFirst() {
        let selector = SemanticSelector(
            id: .transportPlayButton,
            requiredRole: "AXButton",
            allowedSubroles: [],
            titleAliases: ["en": ["Play"]],
            ancestorConstraints: [],
            attributePredicates: [],
            geometryHint: nil,
            minimumConfidence: 0.25,
            ambiguityPolicy: .failClosed
        )
        let duplicate = candidate(identifier: nil, role: "AXButton", title: "Play")

        let resolution = resolve(selector, in: [duplicate, duplicate], locale: "en")

        #expect(resolution == .ambiguous(indices: [0, 1]))
        #expect(!canMutate(resolution))
    }

    @Test func noMatchFailsClosed() {
        let resolution = resolve(
            playSelector(),
            in: [candidate(identifier: nil, role: "AXSlider", title: "Volume")],
            locale: "en"
        )

        #expect(resolution == .notFound)
        #expect(!canMutate(resolution))
    }

    @Test func unsupportedSignatureFailsClosed() {
        let resolution = resolve(
            playSelector(),
            in: [candidate(identifier: "play-control", role: "", title: "Play")],
            locale: "en"
        )

        #expect(resolution == .unsupportedSignature)
        #expect(!canMutate(resolution))
    }

    @Test func identifierEvidenceOutranksGeometry() {
        let selector = playSelector(geometryHint: GeometryHint(x: 10, y: 10, width: 20, height: 20))
        let candidates = [
            candidate(identifier: "play-control", role: "AXButton", title: nil),
            candidate(
                identifier: nil,
                role: "AXButton",
                title: nil,
                geometry: GeometryHint(x: 10, y: 10, width: 20, height: 20)
            ),
        ]

        #expect(confidence(of: candidates[0], against: selector) > confidence(of: candidates[1], against: selector))
        #expect(resolve(selector, in: candidates, locale: "en") == .exact(index: 0))
    }

    @Test func geometryAloneCannotReachHighConfidence() {
        let selector = SemanticSelector(
            id: .mixerStripVolumeFader,
            requiredRole: "AXSlider",
            allowedSubroles: [],
            titleAliases: [:],
            ancestorConstraints: [],
            attributePredicates: [],
            geometryHint: GeometryHint(x: 0, y: 0, width: 10, height: 100),
            minimumConfidence: 0.75,
            ambiguityPolicy: .failClosed
        )
        let geometryOnly = candidate(
            identifier: nil,
            role: "AXSlider",
            title: nil,
            geometry: GeometryHint(x: 0, y: 0, width: 10, height: 100)
        )

        #expect(confidence(of: geometryOnly, against: selector) < selector.minimumConfidence)
        #expect(resolve(selector, in: [geometryOnly], locale: "en") == .notFound)
    }

    @Test func confidenceDropAndMissingSelectorsReportAffectedOperations() {
        let changed = drift(
            previous: [.mixerStripVolumeFader: 0.95],
            current: [.mixerStripVolumeFader: 0.40],
            roleChanges: [.mixerStripVolumeFader: ["AXSlider→AXGroup"]]
        )
        let missing = drift(
            previous: [.transportPlayButton: 0.95],
            current: [:],
            roleChanges: [:]
        )

        #expect(changed == [
            SelectorDrift(
                selectorID: .mixerStripVolumeFader,
                status: .changed,
                previousConfidence: 0.95,
                currentConfidence: 0.40,
                changedRoles: ["AXSlider→AXGroup"],
                affectedOperations: [.mixerSetVolume]
            ),
        ])
        #expect(missing.first?.status == .missing)
        #expect(missing.first?.affectedOperations == [.transportPlay, .transportStop])
    }

    @Test func qualificationReusePolicyFailsClosedOnUnsafeDrift() {
        let stable = makeDrift(status: .stable, previous: 0.95, current: 0.94)
        let minor = makeDrift(status: .minorDrift, previous: 0.95, current: 0.82)
        let changed = makeDrift(status: .changed, previous: 0.95, current: 0.50)
        let unknown = makeDrift(status: .missing, previous: 0.95, current: 0)

        #expect(policy(for: stable) == .reuseFull)
        #expect(policy(for: minor) == .readOnlyOnly)
        #expect(policy(for: changed) == .failClosedMutation)
        #expect(policy(for: unknown) == .failClosedMutation)
    }

    @Test func fingerprintRoundTripsWithoutNameFields() throws {
        let fingerprint = UIFingerprint(
            logicVariant: "creator",
            logicVersion: "11.2",
            locale: "ko",
            windowType: "main",
            viewMode: "mixer",
            sanitizedHierarchyHash: "sha256:abc123"
        )
        let data = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(UIFingerprint.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(decoded == fingerprint)
        #expect(Set(object.keys) == [
            "logicVariant",
            "logicVersion",
            "locale",
            "windowType",
            "viewMode",
            "sanitizedHierarchyHash",
        ])
    }

    @Test func selectorIDsAreCompleteAndFeatureFlagDefaultsOff() {
        #expect(SelectorID.allCases == [
            .transportPlayButton,
            .trackHeaderNameField,
            .mixerStripVolumeFader,
            .mixerStripSendSlot,
            .pluginWindowTitle,
            .pluginParameterControl,
            .projectSaveFilenameField,
        ])

        let key = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr007SelectorAtlas)
    }

    private func playSelector(geometryHint: GeometryHint? = nil) -> SemanticSelector {
        SemanticSelector(
            id: .transportPlayButton,
            requiredRole: "AXButton",
            allowedSubroles: [],
            titleAliases: ["en": ["Play"], "ko": ["재생"]],
            ancestorConstraints: [],
            attributePredicates: [.axIdentifier("play-control")],
            geometryHint: geometryHint,
            minimumConfidence: 0.75,
            ambiguityPolicy: .failClosed
        )
    }

    private func candidate(
        identifier: String?,
        role: String,
        title: String?,
        geometry: GeometryHint? = nil
    ) -> ResolvableCandidate {
        ResolvableCandidate(
            axIdentifier: identifier,
            role: role,
            subrole: nil,
            title: title,
            ancestors: [],
            attributes: [:],
            valueSignature: nil,
            geometry: geometry
        )
    }

    private func makeDrift(
        status: SelectorDriftStatus,
        previous: Double,
        current: Double
    ) -> SelectorDrift {
        SelectorDrift(
            selectorID: .transportPlayButton,
            status: status,
            previousConfidence: previous,
            currentConfidence: current,
            changedRoles: [],
            affectedOperations: [.transportPlay, .transportStop]
        )
    }
}
