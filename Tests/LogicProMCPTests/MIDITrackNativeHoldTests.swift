@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@MainActor
private struct MIDIHoldFixture {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let rail: AXUIElement
    let headers: [AXUIElement]
    let runtime: AXLogicProElements.Runtime
    let observation = MIDITrackFileExport.Observation(projectReference: "prj_current", projectPath: "/fixture.logicx",
        coverage: .complete, tracks: [
            .init(index: 0, reference: "trk_target", name: "Target"),
            .init(index: 1, reference: "trk_peer", name: "Peer"),
        ])

    var bindings: [AXTrackBinding.Binding] {
        headers.map { .init(window: window, header: $0, document: "file:///fixture.logicx/", runtime: runtime) }
    }

    func capture(fault: String = "") -> SessionPopulationObservation.Capture {
        let now = Date()
        let project = ProjectInfo(name: "Fixture", filePath: "/fixture.logicx")
        let tracks = observation.tracks.enumerated().map { index, row in
            var state = TrackState(id: index, name: row.name, type: .softwareInstrument, isStackHeader: false)
            state.physicalBinding = fault == "missing_binding" ? nil : bindings[index]
            return state
        }
        let boundary = StateCache.CaptureBoundary(versions: [:], occlusionRevision: 0, hasDocument: true, axOccluded: false)
        var fresh = SessionPopulationObservation.FreshPopulation(project: project, tracks: tracks, strips: nil,
            fileTrackCount: 2, beganAt: now, endedAt: now, stable: true)
        fresh.hiddenTracksShown = true; fresh.populationEndSource = "ax_all_shown_single_page"
        return .init(before: boundary, after: boundary, projectEpoch: 1, project: project,
            tracks: tracks, tracksFetchedAt: now, channelStrips: [], mixerFetchedAt: .distantPast,
            fileTrackCount: 2, projectFileNotBound: false, requestedProjectMatches: fault != "wrong_project",
            referencesEnabled: true, targetSnapshot: .init(projectEpoch: 1, topologyGeneration: 0),
            issued: .init(byRow: observation.tracks.map { .init(rawValue: $0.reference!) }, byTrackIndex: [:], ambiguousTrackIndices: []),
            projectIssuance: .issued(.init(rawValue: "prj_current")), beganAt: now, endedAt: now,
            freshPopulation: fault == "cached" ? nil : fresh)
    }

    init() {
        app = builder.element(0); window = builder.element(1); rail = builder.element(2)
        headers = [builder.element(3), builder.element(5)]
        builder.setRole(app, kAXApplicationRole as String)
        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole)
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///fixture.logicx/")
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setRole(rail, kAXListRole as String)
        builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(window, [rail]); builder.setChildren(rail, headers)
        for (index, name) in ["Target", "Peer"].enumerated() {
            let field = builder.element(index == 0 ? 4 : 6)
            builder.setRole(headers[index], kAXLayoutItemRole as String)
            builder.setRole(field, kAXTextFieldRole as String)
            builder.setAttribute(field, kAXValueAttribute as String, name)
            builder.setChildren(headers[index], [field])
        }
        runtime = builder.makeLogicRuntime(appElement: app)
    }
}

@MainActor @Test func midiNativeHoldRetainsActualHeadersWithoutUIActions() throws {
    let fixture = MIDIHoldFixture()
    let acquired = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    let hold = try #require(acquired)
    #expect(hold.isCurrent())
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiNativeHoldRejectsSameNameReplacementAndOtherDocumentWindow() throws {
    let fixture = MIDIHoldFixture()
    let acquired = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    let hold = try #require(acquired)
    let replacement = fixture.builder.element(7), field = fixture.builder.element(8)
    fixture.builder.setRole(replacement, kAXLayoutItemRole as String)
    fixture.builder.setRole(field, kAXTextFieldRole as String)
    fixture.builder.setAttribute(field, kAXValueAttribute as String, "Target")
    fixture.builder.setChildren(replacement, [field])
    fixture.builder.setChildren(fixture.rail, [replacement, fixture.headers[1]])
    #expect(!hold.isCurrent())
    fixture.builder.setChildren(fixture.rail, fixture.headers)
    #expect(!hold.isCurrent(), "An observed native identity loss is terminal for this hold")
    let reacquired = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    let next = try #require(reacquired)
    fixture.builder.setAttribute(fixture.app, kAXMainWindowAttribute as String, fixture.builder.element(9))
    #expect(!next.isCurrent())
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiNativeHoldRejectsUnboundDocumentOrLostReadPermission() {
    let fixture = MIDIHoldFixture()
    let refusedPermission = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { false })
    #expect(refusedPermission == nil)
    fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///other.logicx/")
    let refusedDocument = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    #expect(refusedDocument == nil)
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiNativeHoldDoesNotReconstructCaptureCustodyFromEqualNames() {
    let fixture = MIDIHoldFixture()
    let replacement = fixture.builder.element(7), field = fixture.builder.element(8)
    fixture.builder.setRole(replacement, kAXLayoutItemRole as String)
    fixture.builder.setRole(field, kAXTextFieldRole as String)
    fixture.builder.setAttribute(field, kAXValueAttribute as String, "Target")
    fixture.builder.setChildren(replacement, [field])
    fixture.builder.setChildren(fixture.rail, [replacement, fixture.headers[1]])
    let refused = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    #expect(refused == nil)
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiExportProviderUsesTheRegisteredCaptureBindingsAndRetiresLostCustody() async throws {
    let fixture = MIDIHoldFixture()
    let runtime = MIDITrackExportProvider.makeRuntime(projectReference: "prj_current",
        acquire: { _ in fixture.capture() }, nativeRuntime: fixture.runtime)
    try await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
        let observation = try await runtime.observe()
        #expect(observation.coverage == .complete && observation.tracks.map(\.reference) == ["trk_target", "trk_peer"])
        #expect(await runtime.stillCurrent(observation))
        fixture.builder.setChildren(fixture.rail, [])
        #expect(!(await runtime.stillCurrent(observation)))
        fixture.builder.setChildren(fixture.rail, fixture.headers)
        #expect(!(await runtime.stillCurrent(observation)))
    }
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test(arguments: ["cached", "missing_binding", "wrong_project"])
func midiExportProviderRefusesUnqualifiedCapturesWithoutUIActions(fault: String) async throws {
    let fixture = MIDIHoldFixture()
    let runtime = MIDITrackExportProvider.makeRuntime(projectReference: "prj_current",
        acquire: { _ in fixture.capture(fault: fault) }, nativeRuntime: fixture.runtime)
    await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
        do { _ = try await runtime.observe(); Issue.record("Unqualified capture was admitted") } catch { }
    }
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiExportProviderChecksOperationOwnershipBeforeCallingTheProducer() async {
    let fixture = MIDIHoldFixture()
    var acquired = false
    let runtime = MIDITrackExportProvider.makeRuntime(projectReference: "prj_current",
        acquire: { _ in acquired = true; return fixture.capture() }, nativeRuntime: fixture.runtime)
    do { _ = try await runtime.observe(); Issue.record("Unowned acquisition was admitted") } catch { }
    #expect(!acquired)
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test(arguments: ["cancellation", "deadline"])
func midiTemporaryNameRestorationNarrowlySurvivesTermination(reason: String) async {
    let admitted = await Task { @MainActor in
        if reason == "cancellation" { withUnsafeCurrentTask { $0?.cancel() } }
        let context = OperationTraceContext(
            mutationGateAcquired: true,
            deadline: reason == "deadline" ? ContinuousClock.now : nil,
            cancellationRequested: { reason == "cancellation" })
        return await OperationTraceContext.$current.withValue(context) {
            #expect(!ExactTrackNameAdapter.operationPermitted())
            do {
                try SessionPopulationObservation.requireOwnedAcquisition()
                Issue.record("Ordinary cancelled acquisition was admitted")
            } catch { }
            return await ExactTrackNameAdapter.withOwnedTemporaryNameRestoration {
                guard ExactTrackNameAdapter.operationPermitted() else { return false }
                do {
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    return true
                } catch {
                    return false
                }
            }
        }
    }.value
    #expect(admitted)
}
