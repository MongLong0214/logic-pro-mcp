@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private final class ExactNameFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let header: AXUIElement
    let field: AXUIElement
    let rail: AXUIElement
    let cache = StateCache()
    let registry = TargetRegistry()
    let router = ChannelRouter()
    private(set) var writes: [String] = []
    private(set) var events: [String] = []
    var editOnPress: String?
    var hideReadbackAfterSet = false
    var acknowledgementOnly = false
    var onPress: (@Sendable () -> Void)?
    var onConfirm: (@Sendable () -> Void)?
    var onNameReadAfterWrite: (@Sendable () -> Void)?

    init(_ name: String = "A") {
        app = builder.element(968_100)
        window = builder.element(968_101)
        rail = builder.element(968_102)
        header = builder.element(968_103)
        field = builder.element(968_104)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "Fixture - Tracks")
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/ExactName.logicx")
        builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(header, kAXSelectedAttribute as String, true)
        builder.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
        builder.setAttribute(field, kAXDescriptionAttribute as String, name)
        builder.setAttribute(field, kAXValueAttribute as String, "0")
        builder.setChildren(field, [])
        builder.setChildren(header, [field])
        builder.setChildren(rail, [header])
        builder.setChildren(window, [rail])
        builder.setChildren(app, [window])
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    var runtime: AXLogicProElements.Runtime {
        AXLogicProElements.Runtime(
            logicProPID: { 4242 },
            ax: builder.makeAXRuntime(
                appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    if !writes.isEmpty, CFEqual(element, field), attribute == kAXDescriptionAttribute as String {
                        onNameReadAfterWrite?()
                    }
                    if hideReadbackAfterSet, !writes.isEmpty, CFEqual(element, field),
                       attribute == kAXDescriptionAttribute as String { return .some(nil) }
                    return nil
                },
                setAttributeHandler: { [self] element, attribute, value in
                    guard CFEqual(element, field), attribute == kAXValueAttribute as String,
                          let name = value as? String else {
                        Issue.record("Unexpected exact-name fixture setter")
                        return false
                    }
                    writes.append(name)
                    builder.setAttribute(field, kAXDescriptionAttribute as String, name)
                    return true
                },
                performActionHandler: { [self] element, action in
                    guard CFEqual(element, field),
                          [kAXPressAction as String, kAXConfirmAction as String].contains(action) else {
                        Issue.record("Unexpected exact-name fixture action")
                        return false
                    }
                    events.append(action)
                    if action == kAXPressAction as String, let editOnPress {
                        builder.setAttribute(field, kAXDescriptionAttribute as String, editOnPress)
                    }
                    if action == kAXPressAction as String { onPress?() }
                    if action == kAXConfirmAction as String { onConfirm?() }
                    return true
                },
                executeAppleScript: { _ in .error("Injected AX runtime refuses scripts") }
            ),
            executeAppleScript: { _ in .error("Injected runtime refuses scripts") },
            onScreenWindowList: { [] },
            postPopupMenuEscape: { Issue.record("Unexpected Escape") },
            focusedApplicationPID: { 4242 }
        )
    }

    func execute(_ params: [String: String]) -> ChannelResult {
        if acknowledgementOnly { return .success("acknowledged") }
        return AccessibilityChannel.defaultRenameTrack(
            params: params, runtime: runtime,
            mouseRuntime: AXMouseHelper.Runtime(
                postMouseEvent: { _, _, _ in Issue.record("Unexpected mouse event"); return false },
                postKeyEvent: { _ in Issue.record("Unexpected key event"); return false },
                postUnicodeScalar: { _ in Issue.record("Unexpected typing"); return false },
                sleepMicros: { _ in },
                postFlaggedKeyEvent: { _, _ in Issue.record("Unexpected flagged key"); return false }
            ),
            processRuntime: ProcessUtils.Runtime(
                logicProPID: { 4242 }, fallbackLogicProPID: { 4242 }, logicProRunning: { true },
                activateLogicPro: { false }, logicIsFrontmost: { true }, logicProBundleURL: { nil }
            )
        )
    }

    func prepare() async throws -> (TargetReference, TargetReference) {
        await cache.updateTracks([AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime.ax)])
        let snapshot = await registry.currentSnapshot
        let project = await ProjectReferenceIssuance.issue(
            cached: ProjectInfo(name: "ExactName", filePath: "/tmp/ExactName.logicx"),
            registry: registry, snapshot: snapshot
        )
        guard case .issued(let projectRef) = project else {
            throw NSError(domain: "ExactNameFixture", code: 1)
        }
        let refs = try #require(await TrackReferenceIssuance.issue(
            for: await cache.getTracks(), registry: registry, snapshot: snapshot
        ))
        await router.register(ExactNameChannel(self))
        return (projectRef, try #require(refs.byTrackIndex[0]))
    }

    func rename(project: TargetReference, target: TargetReference, expected: String?, desired: String) async -> CallTool.Result {
        var params: [String: Value] = ["project_ref": .string(project.rawValue),
                                       "target_ref": .string(target.rawValue), "name": .string(desired)]
        if let expected { params["expected_name"] = .string(expected) }
        let runtime = runtime
        return await TrackDispatcher.handle(
            command: "rename", params: params, router: router, cache: cache, targetRegistry: registry,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
        )
    }

    func apply(project: TargetReference, target: TargetReference, before: String, after: String) async -> ExactTrackNameAdapter.Receipt {
        let runtime = runtime
        return await ExactTrackNameAdapter.apply(
            .init(projectReference: project, targetReference: target, expectedBefore: before, desiredAfter: after),
            router: router, cache: cache, registry: registry,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
        )
    }

    func inverse(_ proof: ExactTrackNameAdapter.OwnedInverse) async -> ExactTrackNameAdapter.Receipt {
        let runtime = runtime
        return await ExactTrackNameAdapter.inverse(
            proof, router: router,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
        )
    }
}

private actor ExactNameChannel: Channel {
    nonisolated let id = ChannelID.accessibility
    let fixture: ExactNameFixture
    init(_ fixture: ExactNameFixture) { self.fixture = fixture }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "Injected exact-name fixture") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "track.rename" else { return .error("Unexpected route") }
        return fixture.execute(params)
    }
}

@Suite("#968 exact-local track naming adapter")
struct Issue968ExactTrackNameAdapterTests {
    @Test(arguments: ["C", "B"])
    func staleBeforeAfterVerifiedRenameOnSameReferenceRefusesBeforeWrite(desired: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            let changed = await f.rename(project: project, target: target, expected: nil, desired: "B")
            let changedBody = try #require(sharedJSONObject(sharedToolText(changed)))
            #expect(try #require(changedBody["state"] as? String) == "A")
            #expect(f.writes == ["B"])
            let stale = await f.rename(project: project, target: target, expected: "A", desired: desired)
            let isError = stale.isError ?? false
            #expect(isError)
            #expect(f.writes == ["B"])
            let binding = try #require(await f.registry.resolve(target))
            #expect(binding.descriptor.trackName == "B")
        }
    }

    @Test func actualHeldFieldBeforeSetterMustStillMatchExpectedBytes() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.editOnPress = "User edit"
            let result = await f.rename(project: project, target: target, expected: "A", desired: "C")
            let isError = result.isError ?? false
            #expect(isError)
            #expect(f.writes.isEmpty)
            #expect(AXLogicProElements.trackName(at: 0, runtime: f.runtime) == "User edit")
        }
    }

    @Test func acknowledgementWithoutActualReadbackCannotRebindExactRequest() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.acknowledgementOnly = true
            let result = await f.rename(project: project, target: target, expected: "A", desired: "C")
            let isError = result.isError ?? false
            #expect(isError)
            let binding = try #require(await f.registry.resolve(target))
            #expect(binding.descriptor.trackName == "A")
            #expect(await f.cache.getTracks().first?.name == "A")
            #expect(f.writes.isEmpty)
        }
    }

    @Test func exactAlreadySatisfiedUnselectedTargetRequiresNoActuationOrInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("  Same, \"raw\"  ")
            let (project, target) = try await f.prepare()
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            let receipt = await f.apply(project: project, target: target, before: "  Same, \"raw\"  ", after: "  Same, \"raw\"  ")
            #expect(receipt.status == .alreadySatisfied)
            #expect(receipt.survivingReference == target)
            #expect(receipt.inverse == nil)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax))
            #expect(!selected)
        }
    }

    @Test(arguments: ["Aux, 1", "\"Quoted\"", "  padded 🎹  ", "q\u{0323}\u{0301}"])
    func rawNamesAndOwnedInverseUseActualReadbackAndSameReference(name: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let before = "q\u{0301}\u{0323}"
            let f = ExactNameFixture(before)
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: before, after: name)
            #expect(receipt.status == .applied)
            #expect(try #require(receipt.before).utf8.elementsEqual(before.utf8))
            #expect(try #require(receipt.after).utf8.elementsEqual(name.utf8))
            #expect(receipt.survivingReference == target)
            #expect(f.writes.count == 1)
            #expect(try #require(f.writes.first).utf8.elementsEqual(name.utf8))
            let reversed = await f.inverse(try #require(receipt.inverse))
            #expect(reversed.status == .applied)
            #expect(try #require(reversed.before).utf8.elementsEqual(name.utf8))
            #expect(try #require(reversed.after).utf8.elementsEqual(before.utf8))
            #expect(reversed.survivingReference == target)
            #expect(f.writes.count == 2)
            let binding = try #require(await f.registry.resolve(target))
            #expect(binding.descriptor.trackName.utf8.elementsEqual(before.utf8))
        }
    }

    @Test func ownedInverseRefusesASeparateUserEdit() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            let applied = await f.apply(project: project, target: target, before: "A", after: "B")
            let inverse = try #require(applied.inverse)
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "User edit")
            let refused = await f.inverse(inverse)
            #expect(refused.status == .rejectedBeforeWrite)
            #expect(refused.inverse == nil)
            #expect(f.writes == ["B"])
            #expect(AXLogicProElements.trackName(at: 0, runtime: f.runtime) == "User edit")
        }
    }

    @Test func lostAfterReadbackStopsWithoutRetryOrOwnedInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.hideReadbackAfterSet = true
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.before == "A")
            #expect(receipt.after == nil)
            #expect(receipt.inverse == nil)
            #expect(receipt.survivingReference == nil)
            #expect(f.writes == ["B"])
            #expect(f.events == [kAXPressAction as String, kAXConfirmAction as String])
            #expect(await f.cache.getTracks().first?.name == "A")
            #expect(try #require(await f.registry.resolve(target)).descriptor.trackName == "A")
        }
    }

    @Test(arguments: ["", String(repeating: "x", count: 129), "line\nfeed"])
    func invalidRawNamesAreRejectedBeforeAnyWrite(name: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: "A", after: name)
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(receipt.inverse == nil)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
        }
    }

    @Test(arguments: ["project", "topology", "document", "cancel", "ownership", "deadline"])
    func changedProjectTopologyOrOperationOwnershipCannotWrite(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            if change == "project" { await f.registry.bumpProjectEpoch() }
            if change == "topology" { await f.registry.bumpTopologyGeneration() }
            if change == "document" {
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
            }
            let context = OperationTraceContext(
                mutationGateAcquired: true, ownsGate: { change != "ownership" },
                deadline: change == "deadline" ? ContinuousClock.now : nil,
                cancellationRequested: { change == "cancel" }
            )
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "B")
            }
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            #expect(receipt.inverse == nil)
        }
    }

    @Test func byteDistinctEquivalentExpectedBeforeIsNotAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("q\u{0301}\u{0323}")
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: "q\u{0323}\u{0301}", after: "B")
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.writes.isEmpty)
            #expect(receipt.inverse == nil)
        }
    }

    @Test func duplicateDesiredNameDoesNotGrantContinuityButKeepsActualNameObservation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let other = f.builder.element(968_110)
            let otherField = f.builder.element(968_111)
            f.builder.setAttribute(other, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(other, kAXSelectedAttribute as String, false)
            f.builder.setAttribute(otherField, kAXRoleAttribute as String, kAXTextFieldRole as String)
            f.builder.setAttribute(otherField, kAXDescriptionAttribute as String, "Other")
            f.builder.setAttribute(otherField, kAXValueAttribute as String, "1")
            f.builder.setChildren(otherField, [])
            f.builder.setChildren(other, [otherField])
            f.builder.setChildren(f.rail, [f.header, other])
            let (project, target) = try await f.prepare()
            // A separate edit creates a collision only after our setter, at Confirm.
            // Initial duplicate evidence has its own pre-write refusal test below.
            f.onConfirm = {
                f.builder.setAttribute(otherField, kAXDescriptionAttribute as String, "B")
            }
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.before == "A")
            #expect(receipt.after == "B")
            #expect(receipt.survivingReference == nil)
            #expect(receipt.inverse == nil)
            #expect(f.writes == ["B"])
            #expect(AXLogicProElements.trackName(at: 1, runtime: f.runtime) == "B")
        }
    }

    @Test(arguments: ["remote", "localhost", ""])
    func actualDocumentAuthorityMustBeLocalBeforeActuation(host: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file://\(host)/tmp/ExactName.logicx")
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            if host == "remote" {
                #expect(receipt.status == .rejectedBeforeWrite)
                #expect(f.writes.isEmpty)
                #expect(f.events.isEmpty)
                #expect(receipt.inverse == nil)
            } else {
                #expect(receipt.status == .applied)
                #expect(f.writes == ["B"])
                #expect(receipt.survivingReference == target)
            }
        }
    }

    @Test func unsupportedDuplicateContinuityIsExposedBeforeSemanticWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let other = f.builder.element(968_120)
            let otherField = f.builder.element(968_121)
            f.builder.setAttribute(other, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(other, kAXSelectedAttribute as String, false)
            f.builder.setAttribute(otherField, kAXRoleAttribute as String, kAXTextFieldRole as String)
            f.builder.setAttribute(otherField, kAXDescriptionAttribute as String, "B")
            f.builder.setAttribute(otherField, kAXValueAttribute as String, "1")
            f.builder.setChildren(otherField, [])
            f.builder.setChildren(other, [otherField])
            f.builder.setChildren(f.rail, [f.header, other])
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            #expect(receipt.inverse == nil)
            #expect(AXLogicProElements.trackName(at: 0, runtime: f.runtime) == "A")
            #expect(AXLogicProElements.trackName(at: 1, runtime: f.runtime) == "B")
        }
    }

    @Test func documentSwitchDuringDecidingAfterReadCannotGrantOwnedInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.onNameReadAfterWrite = {
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file://remote/tmp/ExactName.logicx")
            }
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.survivingReference == nil)
            #expect(receipt.inverse == nil)
            #expect(f.writes == ["B"])
            #expect(await f.cache.getTracks().first?.name == "A")
        }
    }
}
