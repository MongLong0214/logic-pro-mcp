@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Actual header extraction -> issuance -> shared mutation-index resolution.
/// Getter-only fixtures: no channel/router execution or native writes.
@Suite("#965 reference resolution keeps raw track-name identity")
struct Issue965ReferenceNameIdentityTests {
    private static let operations: [OperationID] = [
        .tracksRename, .mixerSetVolume, .mixerSetPan, .tracksMute, .tracksSolo, .tracksArm,
    ]
    private static let distinctPairs = [
        (" Bass", "Bass "), ("q\u{0301}\u{0323}", "q\u{0323}\u{0301}"),
    ]

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let fields: [AXUIElement]
        let runtime: AXLogicProElements.Runtime
        let cache: StateCache
        let registry: TargetRegistry
        let target: TargetReference
    }

    private func fixture(names: [String]) async throws -> Fixture {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(965_100)
        let window = b.element(965_101)
        let rail = b.element(965_102)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(window, kAXTitleAttribute as String, "Fixture - Tracks")
        b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        var headers: [AXUIElement] = []
        var fields: [AXUIElement] = []
        for (index, name) in names.enumerated() {
            let header = b.element(965_110 + index * 2)
            let field = b.element(965_111 + index * 2)
            b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, name)
            b.setAttribute(field, kAXValueAttribute as String, "0")
            if name == "0" {
                // A field's "0" is the existing numeric placeholder. Exercise
                // a legitimate zero NAME through the readable header title.
                b.setAttribute(field, kAXDescriptionAttribute as String, "")
                b.setAttribute(header, kAXTitleAttribute as String, name)
            }
            b.setChildren(field, [])
            b.setChildren(header, [field])
            headers.append(header)
            fields.append(field)
        }
        b.setChildren(rail, headers)
        b.setChildren(window, [rail])
        b.setChildren(app, [window])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        let runtime = b.makeLogicRuntime(
            appElement: app, setAttributeHandler: { _, _, _ in
                Issue.record("identity readers must not write")
                return false
            }, performActionHandler: { _, _ in
                Issue.record("identity readers must not act")
                return false
            }, executeAppleScript: { _ in
                Issue.record("identity readers must not execute AppleScript")
                return .error("unexpected script")
            }
        )
        let tracks = headers.enumerated().map {
            AXValueExtractors.extractTrackState(from: $0.element, index: $0.offset, runtime: runtime.ax)
        }
        for (row, name) in zip(tracks, names) {
            #expect(row.liveIdentityBacked)
            #expect(row.name.utf8.elementsEqual(name.utf8))
        }
        let cache = StateCache()
        await cache.updateTracks(tracks)
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let issued = try #require(await TrackReferenceIssuance.issue(
            for: tracks, registry: registry, snapshot: snapshot
        ))
        let target = try #require(issued.byTrackIndex[0])
        return Fixture(builder: b, fields: fields, runtime: runtime,
                       cache: cache, registry: registry, target: target)
    }

    private func resolve(
        _ f: Fixture, operation: OperationID, unreadable: Bool = false
    ) async -> TargetRefResolver.Outcome {
        await TargetRefResolver.resolveMutationIndex(
            ["target_ref": .string(f.target.rawValue)], targetRegistry: f.registry,
            cache: f.cache, operation: operation.rawValue,
            invalidIndexResult: toolInvalidParamsResult("fixture requires explicit index"),
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: f.runtime) },
            liveTrackNames: { unreadable ? nil : AXLogicProElements.trackNames(runtime: f.runtime) }
        )
    }

    private func requireSuccess(_ result: TargetRefResolver.Outcome, target: TargetReference) {
        guard case .success(let resolved) = result else {
            Issue.record("a unique unchanged raw-name reference must resolve")
            return
        }
        #expect(resolved.index == 0)
        #expect(resolved.reference == target)
    }

    private func requireRefusal(
        _ result: TargetRefResolver.Outcome, expectedError: String = "stale_target_reference"
    ) throws {
        guard case .failure(let refusal) = result else {
            Issue.record("a changed, ambiguous, unreadable or stale identity must refuse")
            return
        }
        let body = try #require(sharedJSONObject(sharedToolText(refusal)))
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == expectedError)
    }

    @Test(arguments: operations, ["Bass", " Bass ", " Ba\u{0301}ss ", "0"])
    func unchangedRawNameResolves(_ operation: OperationID, name: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: [name])
            requireSuccess(await resolve(f, operation: operation), target: f.target)
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: operations, distinctPairs)
    func byteDistinctLiveReplacementRefuses(_ operation: OperationID, names: (String, String)) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: [names.0])
            f.builder.setAttribute(f.fields[0], kAXDescriptionAttribute as String, names.1)
            try requireRefusal(await resolve(f, operation: operation))
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: operations, distinctPairs)
    func byteDistinctSiblingsRemainUnique(_ operation: OperationID, names: (String, String)) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: [names.0, names.1])
            requireSuccess(await resolve(f, operation: operation), target: f.target)
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: operations)
    func exactDuplicateSiblingStillRefuses(_ operation: OperationID) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: ["Bass", "Bass"])
            try requireRefusal(await resolve(f, operation: operation), expectedError: "ambiguous_target_name")
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: operations, ["unreadable", "stale"])
    func unavailableIdentityStaysRefused(_ operation: OperationID, fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: ["Bass"])
            if fault == "stale" { await f.registry.bumpTopologyGeneration() }
            try requireRefusal(await resolve(f, operation: operation, unreadable: fault == "unreadable"))
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: operations)
    func byteDistinctCachedNameCannotSatisfyTheBinding(_ operation: OperationID) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: ["q\u{0301}\u{0323}"])
            await f.cache.updateTrack(at: 0) { $0.name = "q\u{0323}\u{0301}" }
            try requireRefusal(await resolve(f, operation: operation))
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: operations)
    func unavailableCensusKeepsRawDiagnosticName(_ operation: OperationID) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try await fixture(names: [" Bass "])
            let result = await resolve(f, operation: operation, unreadable: true)
            try requireRefusal(result)
            guard case .failure(let refusal) = result else { return }
            let body = try #require(sharedJSONObject(sharedToolText(refusal)))
            let observed = try #require(body["observed_track_name"] as? String)
            #expect(observed.utf8.elementsEqual(" Bass ".utf8))
        }
    }
}
