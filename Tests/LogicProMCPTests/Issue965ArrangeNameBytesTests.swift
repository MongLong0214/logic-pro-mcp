@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 Arrange name observations preserve bytes")
struct Issue965ArrangeNameBytesTests {
    enum Source: CaseIterable {
        case fieldDescription, fieldTitle, fieldValue, staticText, quotedDescription, headerTitle
    }

    private func header(_ builder: FakeAXRuntimeBuilder, source: Source, name: String) -> AXUIElement {
        let header = builder.element(965_300)
        let child = builder.element(965_301)
        builder.setRole(header, kAXLayoutItemRole as String)
        builder.setChildren(header, [])
        switch source {
        case .fieldDescription, .fieldTitle, .fieldValue:
            builder.setRole(child, kAXTextFieldRole as String)
            let attribute: String
            switch source {
            case .fieldDescription: attribute = kAXDescriptionAttribute as String
            case .fieldTitle: attribute = kAXTitleAttribute as String
            default: attribute = kAXValueAttribute as String
            }
            builder.setAttribute(child, attribute, name)
            if source != .fieldValue { builder.setAttribute(child, kAXValueAttribute as String, "0") }
            builder.setChildren(child, [])
            builder.setChildren(header, [child])
        case .staticText:
            builder.setRole(child, kAXStaticTextRole as String)
            builder.setAttribute(child, kAXValueAttribute as String, name)
            builder.setChildren(child, [])
            builder.setChildren(header, [child])
        case .quotedDescription:
            builder.setAttribute(header, kAXDescriptionAttribute as String, "1 track ‘\(name)’")
        case .headerTitle:
            builder.setAttribute(header, kAXTitleAttribute as String, name)
        }
        return header
    }

    @Test(arguments: Source.allCases, [" Bass \n", " Ba\u{0301}ss ", "q\u{0323}\u{0301}"])
    func eachExistingSourcePreservesRawBytes(_ source: Source, name: String) throws {
        let builder = FakeAXRuntimeBuilder()
        let header = header(builder, source: source, name: name)
        let ax = builder.makeAXRuntime()
        let state = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: ax)
        #expect(state.liveIdentityBacked)
        #expect(state.name.utf8.elementsEqual(name.utf8))
        let read = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax)
        guard case .success(let candidate) = read else {
            Issue.record("readable name must not become an AX failure")
            return
        }
        let observed = try #require(candidate)
        #expect(observed.utf8.elementsEqual(name.utf8))
        #expect(builder.setCalls.isEmpty)
        #expect(builder.actionCalls.isEmpty)
    }

    @Test(arguments: Source.allCases)
    func whitespaceOnlyRemainsUnobserved(_ source: Source) {
        let builder = FakeAXRuntimeBuilder()
        let header = header(builder, source: source, name: " \t\n ")
        let ax = builder.makeAXRuntime()
        let state = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: ax)
        #expect(!state.liveIdentityBacked)
        let read = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax)
        let unknown: Bool
        if case .success(nil) = read { unknown = true } else { unknown = false }
        #expect(unknown)
    }

    @Test(arguments: [Source.fieldDescription, .fieldTitle, .fieldValue])
    func numericPlaceholderIsNotAName(_ source: Source) {
        let builder = FakeAXRuntimeBuilder()
        let header = header(builder, source: source, name: " 0 ")
        let state = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: builder.makeAXRuntime())
        #expect(!state.liveIdentityBacked)
    }

    @Test(arguments: [kAXTextFieldRole as String, kAXStaticTextRole as String], [true, false])
    func verifiedReaderCountsByteIdentities(_ role: String, identical: Bool) throws {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(965_310)
        let children = [builder.element(965_311), builder.element(965_312)]
        let first = "q\u{0301}\u{0323}"
        let second = identical ? first : "q\u{0323}\u{0301}"
        #expect(first == second, "this regression must exercise canonical equality")
        for (child, name) in zip(children, [first, second]) {
            builder.setRole(child, role)
            builder.setAttribute(child, role == kAXTextFieldRole as String
                ? kAXDescriptionAttribute as String : kAXValueAttribute as String, name)
            builder.setChildren(child, [])
        }
        builder.setChildren(header, children)
        let read = AXValueExtractors.extractTrackNameResult(from: header, runtime: builder.makeAXRuntime())
        guard case .success(let candidate) = read else {
            Issue.record("ambiguity is an unknown observation, not an AX failure")
            return
        }
        if identical {
            let observed = try #require(candidate)
            #expect(observed.utf8.elementsEqual(first.utf8))
        } else {
            let unknown = candidate == nil
            #expect(unknown)
        }
    }

    @Test(arguments: [TargetKind.track, .mixerStrip, .pluginInsert])
    func registryReissuesByteDistinctNamesWithoutFuzzyLookup(_ kind: TargetKind) async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let old = TargetDescriptor(trackIndex: 0, trackName: "q\u{0301}\u{0323}")
        let new = TargetDescriptor(trackIndex: 0, trackName: "q\u{0323}\u{0301}")
        let oldFingerprint = kind == .pluginInsert
            ? TargetRefResolver.pluginInsertFingerprint(descriptor: old, insert: 0, pluginIdentity: "Channel EQ")
            : old.fingerprint
        let newFingerprint = kind == .pluginInsert
            ? TargetRefResolver.pluginInsertFingerprint(descriptor: new, insert: 0, pluginIdentity: "Channel EQ")
            : new.fingerprint
        #expect(oldFingerprint == newFingerprint)
        #expect(!oldFingerprint.utf8.elementsEqual(newFingerprint.utf8))
        let first = await registry.bind(kind: kind, descriptor: old, fingerprint: oldFingerprint)
        let missing = await registry.issuedReference(kind: kind, descriptor: new,
                                                    fingerprint: newFingerprint, snapshot: snapshot)
        let notIssued = missing == nil
        #expect(notIssued, "lookup must not substitute a byte-distinct old binding")
        let second = await registry.bind(kind: kind, descriptor: new, fingerprint: newFingerprint)
        #expect(first != second)
        let binding = try #require(await registry.resolve(second))
        #expect(binding.descriptor.trackName.utf8.elementsEqual(new.trackName.utf8))
        let stable = await registry.bind(kind: kind, descriptor: new, fingerprint: newFingerprint)
        #expect(stable == second)
        #expect(await registry.issuedReference(kind: kind, descriptor: old,
                                              fingerprint: oldFingerprint, snapshot: snapshot) == first)
        #expect(await registry.issuedReference(kind: kind, descriptor: new,
                                              fingerprint: newFingerprint, snapshot: snapshot) == second)
    }

    @Test(arguments: [TargetKind.track, .mixerStrip, .pluginInsert])
    func bindingFingerprintCannotSubstituteCanonicalEquivalentBytes(_ kind: TargetKind) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let old = TargetDescriptor(trackIndex: 0, trackName: "q\u{0301}\u{0323}")
            let different = TargetDescriptor(trackIndex: 0, trackName: "q\u{0323}\u{0301}")
            let fingerprint = kind == .pluginInsert
                ? TargetRefResolver.pluginInsertFingerprint(descriptor: different, insert: 0, pluginIdentity: "Channel EQ")
                : different.fingerprint
            let reference = await registry.bind(kind: kind, descriptor: old, fingerprint: fingerprint)
            let binding = try #require(await registry.resolve(reference))
            if kind == .pluginInsert {
                let identity = TargetRefResolver.pluginInsertIdentity(from: binding)
                let refused = identity == nil
                #expect(refused, "a canonical-equivalent prefix is not the observed descriptor bytes")
            }
            let cache = StateCache()
            await cache.updateTracks([TrackState(id: 0, name: old.trackName, type: .audio)])
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)], targetRegistry: registry,
                cache: cache, operation: "fixture",
                invalidIndexResult: toolInvalidParamsResult("explicit index required"), acceptedKinds: [kind]
            )
            guard case .failure(let result) = outcome else {
                Issue.record("byte-distinct fingerprint must refuse")
                return
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "stale_target_reference")
        }
    }

    @Test func rawWhitespaceMustNotTurnInspectorLabelsIntoTrackAuthority() async throws {
        let names = ["Region: ", "Loop:\t", "Transpose:\n"]
        let tracks = names.enumerated().map { index, name in
            let builder = FakeAXRuntimeBuilder()
            let header = header(builder, source: .fieldDescription, name: name)
            let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: builder.makeAXRuntime())
            #expect(track.name.utf8.elementsEqual(name.utf8))
            return track
        }
        let inventory = TrackReferenceIssuance.liveInventory(tracks)
        #expect(inventory.isEmpty)
        let registry = TargetRegistry()
        let issued = try #require(await TrackReferenceIssuance.issue(
            for: inventory, registry: registry, snapshot: await registry.currentSnapshot
        ))
        #expect(issued.byRow.isEmpty)
        #expect(issued.byTrackIndex.isEmpty, "preserving raw display bytes must not make inspector labels eligible for references")
    }
}
