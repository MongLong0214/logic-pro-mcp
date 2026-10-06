@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// R1116-002: actual AX extraction and reference issuance feed the actual
/// production saga name primitive, using injected getters only. No writes,
/// channels, server startup, native scripts or compensation are exercised.
@Suite("R1116-002 raw track identity reaches saga before-state")
struct Issue1116SagaRawNameTests {
    private static let operations: [OperationID] = [
        .tracksRename, .mixerSetVolume, .mixerSetPan, .tracksMute, .tracksSolo, .tracksArm,
    ]

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let header: AXUIElement
        let field: AXUIElement
        let runtime: AXLogicProElements.Runtime
        let registry: TargetRegistry
        let target: TargetReference
        let executor: ProductionSagaStepExecutor
    }

    private func fixture(name: String) async throws -> Fixture {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(1116_000)
        let window = b.element(1116_001)
        let rail = b.element(1116_002)
        let header = b.element(1116_003)
        let field = b.element(1116_004)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(window, kAXTitleAttribute as String, "Fixture - Tracks")
        b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
        b.setAttribute(field, kAXDescriptionAttribute as String, name)
        b.setAttribute(field, kAXValueAttribute as String, "0")
        b.setChildren(field, [])
        b.setChildren(header, [field])
        b.setChildren(rail, [header])
        b.setChildren(window, [rail])
        b.setChildren(app, [window])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        let runtime = b.makeLogicRuntime(appElement: app)
        let extracted = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime.ax)
        #expect(extracted.liveIdentityBacked)
        #expect(extracted.name.utf8.elementsEqual(name.utf8))
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let issued = try #require(await TrackReferenceIssuance.issue(
            for: [extracted], registry: registry, snapshot: snapshot
        ))
        let target = try #require(issued.byTrackIndex[0])
        let binding = try #require(await registry.resolve(target))
        #expect(binding.descriptor.trackName.utf8.elementsEqual(name.utf8))
        let reads = SagaLiveReadback(
            readTrackName: { index in SagaLiveReadback.productionTrackName(at: index, runtime: runtime) },
            readTrackVolume: { _ in 0.25 },
            readTrackPan: { _ in -0.5 },
            readTrackToggle: { _, field in field == .solo }
        )
        let executor = ProductionSagaStepExecutor(
            router: ChannelRouter(), cache: StateCache(), targetRegistry: registry,
            dialogPresent: { false }, liveReadback: reads
        )
        return Fixture(builder: b, header: header, field: field, runtime: runtime,
                       registry: registry, target: target, executor: executor)
    }

    private func step(_ operation: OperationID, target: TargetReference) -> SagaStep {
        let key: String = switch operation {
        case .tracksRename: "name"
        case .tracksMute, .tracksSolo, .tracksArm: "enabled"
        default: "value"
        }
        return SagaStep(operationID: operation, targetRef: target, params: [:],
                        expectedInverse: SagaExpectedInverse(operationID: operation, valueParameter: key))
    }

    private func expectedValue(_ operation: OperationID, name: String) -> Value {
        switch operation {
        case .tracksRename: .string(name)
        case .mixerSetVolume: .double(0.25)
        case .mixerSetPan: .double(-0.5)
        case .tracksSolo: .bool(true)
        default: .bool(false)
        }
    }

    @Test("fresh raw-name references remain readable by all six scalar operations",
          arguments: operations, ["Bass", " Bass ", " Ba\u{0301}ss "])
    func issuedRawNameIsReadableBySaga(_ operation: OperationID, name: String) async throws {
        let f = try await fixture(name: name)
        let targetStep = step(operation, target: f.target)
        let observed = await f.executor.readState(targetStep)
        #expect(observed?.value == expectedValue(operation, name: name))
        #expect(observed?.read?.provenance == .liveIndependent)
        let availability = await f.executor.captureBeforeStateAvailability(
            plan: SagaPlan(steps: [targetStep], idempotencyKey: "raw-name-read")
        )
        #expect(availability.count == 1)
        #expect(availability.first?.state?.value == expectedValue(operation, name: name))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("trim-equal or byte-distinct canonical-equivalent replacements never satisfy the reference",
          arguments: operations, [(" Bass", "Bass "), ("q\u{0301}\u{0323}", "q\u{0323}\u{0301}")])
    func byteDistinctReplacementIsNotTheIssuedTrack(_ operation: OperationID, names: (String, String)) async throws {
        let f = try await fixture(name: names.0)
        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, names.1)
        let observed = await f.executor.readState(step(operation, target: f.target))
        #expect(observed == nil)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("a topology bump invalidates a once-readable raw-name reference", arguments: operations)
    func staleRawNameTargetStaysUnavailable(_ operation: OperationID) async throws {
        let f = try await fixture(name: "Bass")
        await f.registry.bumpTopologyGeneration()
        let observed = await f.executor.readState(step(operation, target: f.target))
        #expect(observed == nil)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }
}

extension Issue1116SagaRawNameTests {
    @Test("a present malformed sole Name authority cannot satisfy an issued saga reference",
          arguments: operations, ["number", "null"])
    func malformedNameAuthorityCannotAuthorizeSaga(_ operation: OperationID, shape: String) async throws {
        let f = try await fixture(name: "Bass")
        let payload: AnyObject = shape == "number" ? NSNumber(value: 7) : NSNull()
        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, payload)
        // Both existing builder seams expose the same PRESENT malformed payload.
        // AXTitle is absent and AXValue is the legacy "0" sentinel, so there
        // is no other readable Name authority to borrow after issuance.
        let classic: AnyObject? = AXHelpers.getAttribute(
            f.field, kAXDescriptionAttribute as String, runtime: f.runtime.ax
        )
        let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            f.field, kAXDescriptionAttribute as String, runtime: f.runtime.ax
        )
        #expect((classic as? String) == nil)
        if shape == "number" { #expect(classic is NSNumber) }
        else { #expect(classic is NSNull) }
        switch raw {
        case .success(.some(let observed)):
            if shape == "number" { #expect(observed is NSNumber) }
            else { #expect(observed is NSNull) }
        default:
            Issue.record("the fixture must expose present malformed Name bytes, not absence or AX failure")
        }
        let targetStep = step(operation, target: f.target)
        #expect(await f.executor.readState(targetStep) == nil)
        let unavailable = await f.executor.captureBeforeStateAvailability(
            plan: SagaPlan(steps: [targetStep], idempotencyKey: "malformed-name-read")
        )
        #expect(unavailable.count == 1)
        #expect(unavailable.first?.state == nil)
        // Restoring the original authority makes the SAME issued reference usable.
        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Bass")
        let restored = await f.executor.readState(targetStep)
        #expect(restored?.value == expectedValue(operation, name: "Bass"))
        #expect(restored?.read?.provenance == .liveIndependent)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("byte-distinct field or static Name census cannot authorize saga while same-byte duplicates can",
          arguments: operations, ["field", "static"])
    func ambiguousNameCensusCannotAuthorizeSaga(_ operation: OperationID, source: String) async throws {
        let first = "q\u{0301}\u{0323}"
        let secondName = "q\u{0323}\u{0301}"
        #expect(first == secondName)
        #expect(!first.utf8.elementsEqual(secondName.utf8))
        let f = try await fixture(name: first)
        let second = f.builder.element(1116_006)
        let secondAttribute: String
        if source == "field" {
            f.builder.setAttribute(second, kAXRoleAttribute as String, kAXTextFieldRole as String)
            secondAttribute = kAXDescriptionAttribute as String
            f.builder.setAttribute(second, secondAttribute, secondName)
            f.builder.setAttribute(second, kAXValueAttribute as String, "0")
            f.builder.setChildren(f.header, [f.field, second])
        } else {
            // Retain the existing field but make it unusable, then observe
            // the actual static-text fallback census rather than a name seam.
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "")
            let firstText = f.builder.element(1116_005)
            f.builder.setAttribute(firstText, kAXRoleAttribute as String, kAXStaticTextRole as String)
            f.builder.setAttribute(firstText, kAXValueAttribute as String, first)
            f.builder.setChildren(firstText, [])
            f.builder.setAttribute(second, kAXRoleAttribute as String, kAXStaticTextRole as String)
            secondAttribute = kAXValueAttribute as String
            f.builder.setAttribute(second, secondAttribute, secondName)
            f.builder.setChildren(f.header, [f.field, firstText, second])
        }
        f.builder.setChildren(second, [])
        let targetStep = step(operation, target: f.target)
        #expect(await f.executor.readState(targetStep) == nil)
        let unavailable = await f.executor.captureBeforeStateAvailability(
            plan: SagaPlan(steps: [targetStep], idempotencyKey: "ambiguous-name-read")
        )
        #expect(unavailable.count == 1)
        #expect(unavailable.first?.state == nil)
        // Same-byte duplicate observations retain a legitimate usable target.
        f.builder.setAttribute(second, secondAttribute, first)
        let unambiguous = await f.executor.readState(targetStep)
        #expect(unambiguous?.value == expectedValue(operation, name: first))
        #expect(unambiguous?.read?.provenance == .liveIndependent)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }
}
