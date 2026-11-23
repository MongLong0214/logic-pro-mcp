@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#965 one native Help sample per strip extraction", .serialized)
struct Issue965StripHelpSampleTests {
    @Test("positive insert-control metadata avoids only redundant Help and remains fresh",
          arguments: ["legacy", "noted", "help_only", "unmatched", "cutoff", "fresh"])
    func positiveInsertControlMetadataDoesNotNeedHelp(mode: String) throws {
        final class Calls: @unchecked Sendable { var help = 0, guards = 0 }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let group = builder.element(1_971_995), bypass = builder.element(1_971_996)
        let open = builder.element(1_971_997)
        builder.setRole(group, kAXGroupRole as String)
        builder.setRole(bypass, kAXCheckBoxRole as String)
        builder.setRole(open, kAXButtonRole as String)
        builder.setChildren(group, [bypass, open])
        builder.setChildren(bypass, []); builder.setChildren(open, [])
        let metadataPositive = ["legacy", "noted", "fresh"].contains(mode)
        for (element, label) in [(bypass, "Bypass"), (open, "Open")] {
            builder.setAttribute(element, kAXDescriptionAttribute as String, metadataPositive ? label : "Unclassified control")
            builder.setAttribute(element, kAXHelpAttribute as String, mode == "unmatched" ? "Unrelated Help" : label)
        }
        let base = builder.makeAXRuntime()
        let native: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { element, attribute in
            if attribute == kAXHelpAttribute as String { calls.help += 1 }
            return base.attributeValueResult?(element, attribute) ?? .success(base.attributeValue(element, attribute))
        }
        let raw = AXHelpers.Runtime(axApp: base.axApp,
            attributeValue: { element, attribute in try? native(element, attribute).get() },
            setAttributeValue: base.setAttributeValue,
            children: base.children, performAction: base.performAction, childCount: base.childCount,
            childrenResult: base.childrenResult,
            attributeValueResult: native)
        let failures = AXPluginInstanceIdentity.FailedReads()
        let runtime = mode == "noted" ? AXPluginInstanceIdentity.noting(failures, over: raw) : raw
        let guardian = AXHelpers.HelpReadGuard(allowHelpReads: true, stop: {
            calls.guards += 1
            return mode == "cutoff"
        })
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            let occupied = AXLogicProElements.isOccupiedPluginSlotElement(group, runtime: runtime)
            #expect(occupied == !["unmatched", "cutoff"].contains(mode))
            if metadataPositive {
                #expect(calls.help == 0 && calls.guards == 0,
                    "Fresh sibling metadata already proves both positive controls; no unresolved sibling needs focus-moving Help")
                #expect(!failures.any)
            } else if mode == "cutoff" {
                #expect(calls.guards > 0 && calls.help == 0 && guardian.stopped)
            } else {
                #expect(calls.help > 0 && calls.guards == calls.help,
                    "Unresolved metadata must keep the full guardian on every actual Help read")
            }
            if mode == "fresh" {
                for element in [bypass, open] {
                    builder.setAttribute(element, kAXDescriptionAttribute as String, "Unclassified control")
                    builder.setAttribute(element, kAXHelpAttribute as String, "Unrelated Help")
                }
                #expect(!AXLogicProElements.isOccupiedPluginSlotElement(group, runtime: runtime))
                #expect(calls.help > 0 && calls.guards == calls.help,
                    "The next classification must not reuse an earlier positive metadata sample")
            }
        }
        #expect(builder.actionCalls.isEmpty && builder.setCalls.isEmpty)
    }

    @Test("failure-noting delegation retains one fresh full guard per actual Help read",
          arguments: ["legacy", "typed", "raw_legacy", "raw_typed", "nested", "native_failure", "cutoff", "omitted", "fresh_cutoff"])
    func notedHelpReadGuardsTheNativeBoundaryOnce(mode: String) throws {
        final class Calls: @unchecked Sendable { var guards = 0, native = 0 }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let element = builder.element(1_971_990)
        builder.setAttribute(element, kAXHelpAttribute as String, "Native Help")
        let base = builder.makeAXRuntime()
        let native: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { node, attribute in
            if attribute == kAXHelpAttribute as String {
                calls.native += 1
                if mode == "native_failure" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
            }
            return .success(base.attributeValue(node, attribute))
        }
        let raw = AXHelpers.Runtime(axApp: base.axApp,
            attributeValue: { node, attribute in try? native(node, attribute).get() },
            setAttributeValue: base.setAttributeValue, children: base.children,
            performAction: base.performAction, childCount: base.childCount,
            attributeValueResult: native)
        let failures = AXPluginInstanceIdentity.FailedReads()
        let nestedFailures = AXPluginInstanceIdentity.FailedReads()
        let noted = AXPluginInstanceIdentity.noting(failures, over: raw)
        let runtime = mode == "nested" ? AXPluginInstanceIdentity.noting(nestedFailures, over: noted) : noted
        let guardian = AXHelpers.HelpReadGuard(allowHelpReads: mode != "omitted", stop: {
            calls.guards += 1
            return mode == "cutoff" || (mode == "fresh_cutoff" && calls.guards > 1)
        })
        func read() -> String? {
            switch mode {
            case "legacy": return AXHelpers.getAttribute(element, kAXHelpAttribute as String, runtime: runtime)
            case "raw_legacy": return runtime.attributeValue(element, kAXHelpAttribute as String) as? String
            case "raw_typed": return (try? runtime.attributeValueResult?(element, kAXHelpAttribute as String).get()) as? String
            default:
                let result: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    element, kAXHelpAttribute as String, runtime: runtime)
                return try? result.get()
            }
        }
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            let first = read()
            #expect(calls.guards == 1, "Only the wrapper's deciding native boundary needs the full guard")
            let refused = mode == "cutoff" || mode == "omitted"
            #expect(calls.native == (refused ? 0 : 1))
            #expect(first == (refused || mode == "native_failure" ? nil : "Native Help"))
            if mode == "fresh_cutoff" {
                #expect(read() == nil)
                #expect(calls.guards == 2 && calls.native == 1 && guardian.stopped)
                #expect(read() == nil && calls.guards == 2 && calls.native == 1)
            } else if !refused {
                _ = read()
                #expect(calls.guards == 2 && calls.native == 2,
                    "Delegation must never cache permission for the next physical read")
            }
            if mode == "omitted" { #expect(!guardian.stopped && !failures.any) }
            if mode == "native_failure" { #expect(failures.any) }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test("the actual owned strip reader retains failure-noting plugin provenance over both input runtimes",
          arguments: [false, true])
    func ownedPluginReaderReachesOnlyTheEligibleBatchSeam(noting: Bool) throws {
        final class Calls: @unchecked Sendable { var metadataBatches = 0, helpGuardCalls = 0, bypassHelp = 0 }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let strip = builder.element(1_965_860), insert = builder.element(1_965_861)
        let bypass = builder.element(1_965_862), open = builder.element(1_965_863)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setRole(insert, kAXGroupRole as String)
        builder.setAttribute(insert, kAXDescriptionAttribute as String, "Gain")
        for (control, role, label) in [(bypass, kAXCheckBoxRole as String, "Bypass"), (open, kAXButtonRole as String, "Open")] {
            builder.setRole(control, role)
            builder.setAttribute(control, kAXDescriptionAttribute as String, label)
            builder.setAttribute(control, kAXHelpAttribute as String, label)
            builder.setChildren(control, [])
        }
        builder.setAttribute(bypass, kAXValueAttribute as String, 0)
        builder.setChildren(insert, [bypass, open]); builder.setChildren(strip, [insert])
        let window = builder.element(1_965_864), mixer = builder.element(1_965_865)
        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/OwnedStrip.logicx")
        builder.setRole(mixer, kAXLayoutAreaRole as String)
        builder.setChildren(mixer, [strip]); builder.setChildren(window, [mixer])
        let base = builder.makeAXRuntime()
        let metadata = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute] as [String]
        let native: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { element, attribute in
            if attribute == kAXHelpAttribute as String, CFEqual(element, bypass) { calls.bypassHelp += 1 }
            return base.attributeValueResult?(element, attribute) ?? .success(base.attributeValue(element, attribute))
        }
        let raw = AXHelpers.Runtime(axApp: base.axApp, attributeValue: { try? native($0, $1).get() },
            attributeIsSettable: base.attributeIsSettable, setAttributeValue: base.setAttributeValue,
            children: base.children, performAction: base.performAction, childCount: base.childCount,
            childrenResult: base.childrenResult, attributeValueResult: native,
            attributeValuesResult: { element, attributes in
                if attributes == metadata { calls.metadataBatches += 1 }
                return .success(attributes.map { attribute -> AnyObject in
                    if attribute == kAXChildrenAttribute as String { return base.children(element) as CFArray }
                    return base.attributeValue(element, attribute) ?? NSNull()
                })
            })
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = noting ? AXPluginInstanceIdentity.noting(failures, over: raw) : raw
        if noting { #expect(ax.attributeValuesResult == nil) }
        else { #expect(ax.attributeValuesResult != nil) }
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax)
        let guardian = AXHelpers.HelpReadGuard(stop: { calls.helpGuardCalls += 1; return false })
        try OperationTraceContext.$current.withValue(OperationTraceContext(mutationGateAcquired: true)) {
            try AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                let states = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: logic,
                    window: window, mixer: mixer,
                    readingRouting: false, readingScalarHelp: false, stoppingWhen: { guardian.stopped }))
                #expect(states.first?.pluginsSource == "ax" && states.first?.plugins.first?.name == "Gain")
                #expect(states.first?.physicalBinding != nil)
                let fullyObserved = try #require(states.first?.pluginsFullyObserved)
                #expect(fullyObserved)
                #expect(calls.metadataBatches == 0)
                #expect(calls.helpGuardCalls > 0 && !guardian.stopped && !failures.any,
                    "Independent MIDI/instrument absence still requires its guarded Help census")
                #expect(calls.bypassHelp == 0,
                    "The actual owned reader must not read Bypass Help just to find an Open control already present in sibling metadata")
            }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
    @Test("plugin semantic text pairs fresh non-Help metadata but retains the full separate Help guard",
          arguments: ["healthy", "legacy", "null_fallback", "failed_batch", "malformed_metadata", "help_cutoff", "next_sample"])
    func semanticTextCoalescesOnlyItsFreshMetadata(kind: String) {
        final class Calls: @unchecked Sendable {
            var singles = 0, batches = 0, help = 0, guardCalls = 0
            var blocked = false
        }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let element = builder.element(1_965_870)
        builder.setAttribute(element, kAXIdentifierAttribute as String, "slot-id")
        builder.setAttribute(element, kAXDescriptionAttribute as String, "Audio Plug-in")
        builder.setAttribute(element, kAXTitleAttribute as String, "FX")
        builder.setAttribute(element, kAXHelpAttribute as String, "Native Help")
        let base = builder.makeAXRuntime()
        let metadata = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute] as [String]
        let batch: (@Sendable (AXUIElement, [String]) -> Result<[AnyObject], AXHelpers.AXStatusError>)?
        if kind == "legacy" { batch = nil }
        else {
            batch = { node, attributes in
                calls.batches += 1
                #expect(attributes == metadata && !attributes.contains(kAXHelpAttribute as String))
                if kind == "failed_batch" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                let values = attributes.map { attribute -> AnyObject in
                    if kind == "null_fallback" { return NSNull() }
                    if kind == "malformed_metadata" { return NSNumber(value: 1) }
                    return base.attributeValue(node, attribute) ?? NSNull()
                }
                if kind == "help_cutoff" { calls.blocked = true }
                return .success(values)
            }
        }
        let runtime = AXHelpers.Runtime(axApp: base.axApp, attributeValue: { node, attribute in
            if metadata.contains(attribute) { calls.singles += 1 }
            if attribute == kAXHelpAttribute as String { calls.help += 1 }
            return base.attributeValue(node, attribute)
        }, setAttributeValue: base.setAttributeValue, children: base.children,
            performAction: base.performAction, childCount: base.childCount,
            attributeValueResult: { node, attribute in
                if metadata.contains(attribute) { calls.singles += 1 }
                return .success(base.attributeValue(node, attribute))
            }, attributeValuesResult: batch)
        let guardian = AXHelpers.HelpReadGuard(stop: { calls.guardCalls += 1; return calls.blocked })
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            let first = AXLogicProElements.elementSearchText(element, runtime: runtime)
            if ["failed_batch", "malformed_metadata"].contains(kind) { #expect(first == "native help") }
            else if kind == "help_cutoff" { #expect(first == "slot-id audio plug-in fx") }
            else { #expect(first == "slot-id audio plug-in fx native help") }
            #expect(calls.batches == (kind == "legacy" ? 0 : 1))
            #expect(calls.singles == (["legacy", "null_fallback"].contains(kind) ? 3 : 0))
            #expect(calls.guardCalls == 1 && calls.help == (kind == "help_cutoff" ? 0 : 1))
            if kind == "help_cutoff" { #expect(guardian.stopped) }
            else { #expect(!guardian.stopped) }
            if kind == "next_sample" {
                builder.setAttribute(element, kAXDescriptionAttribute as String, "Changed insert")
                #expect(AXLogicProElements.elementSearchText(element, runtime: runtime) == "slot-id changed insert fx native help")
                #expect(calls.batches == 2 && calls.help == 2 && calls.guardCalls == 2)
            }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
    private final class Reads: @unchecked Sendable {
        let builder: FakeAXRuntimeBuilder
        let input: AXUIElement
        let failFirstInput: Bool
        var counts: [(AXUIElement, Int)] = []
        init(builder: FakeAXRuntimeBuilder, input: AXUIElement, failFirstInput: Bool) {
            self.builder = builder; self.input = input; self.failFirstInput = failFirstInput
        }
        func read(_ element: AXUIElement) -> Result<AnyObject?, AXHelpers.AXStatusError> {
            let index = counts.firstIndex { CFEqual($0.0, element) }
            let count: Int
            if let index { counts[index].1 += 1; count = counts[index].1 }
            else { counts.append((element, 1)); count = 1 }
            if failFirstInput, CFEqual(input, element), count == 1 {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            return .success(builder.attributeValue(element, kAXHelpAttribute as String).map { $0 as AnyObject })
        }
    }

    @Test(arguments: [false, true])
    func scalarOmissionKeepsDescriptionValuesAndDefaultReaderKeepsHelp(readingScalarHelp: Bool) throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(1_965_890)
        let volume = builder.element(1_965_891)
        let pan = builder.element(1_965_892)
        let window = builder.element(1_965_893)
        let mixer = builder.element(1_965_894)
        builder.setRole(strip, kAXLayoutItemRole as String)
        for (slider, name, value) in [(volume, "Volume", 0.75), (pan, "Pan", 0.25)] {
            builder.setRole(slider, kAXSliderRole as String)
            builder.setAttribute(slider, readingScalarHelp ? kAXHelpAttribute as String : kAXDescriptionAttribute as String, name)
            builder.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
            builder.setAttribute(slider, kAXMaxValueAttribute as String, 1.0)
            builder.setAttribute(slider, kAXValueAttribute as String, value)
            builder.setChildren(slider, [])
        }
        builder.setChildren(strip, [volume, pan])
        let reads = Reads(builder: builder, input: volume, failFirstInput: false)
        let runtime = builder.makeLogicRuntime(attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let states = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime,
            window: window, mixer: mixer, readingScalarHelp: readingScalarHelp, stoppingWhen: { false }))
        #expect(states.first?.volume == 0.75)
        #expect(states.first?.pan == 0.25)
        #expect(reads.counts.isEmpty == !readingScalarHelp)
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func requiredSendHelpIsNotPoisonedByScalarOmission(failed: Bool) throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(1_965_895)
        let anchor = builder.element(1_965_896)
        let knob = builder.element(1_965_897)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(anchor, description: "Send", help: "Send slot", x: 0, y: 0, width: 60, height: 20)
        builder.setRole(knob, kAXSliderRole as String)
        builder.setAttribute(knob, kAXDescriptionAttribute as String, "Volume")
        builder.setAttribute(knob, kAXHelpAttribute as String, "Send level knob")
        builder.setAttribute(knob, kAXValueAttribute as String, 0.75)
        builder.setChildren(knob, [])
        builder.setChildren(strip, [anchor, knob])
        let reads = Reads(builder: builder, input: knob, failFirstInput: failed)
        let runtime = builder.makeLogicRuntime(attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let context = OperationTraceContext(mutationGateAcquired: true)
        let outerGuard = AXHelpers.HelpReadGuard(stop: { false })
        let outerSamples = AXHelpers.StripHelpSamples()
        try OperationTraceContext.$current.withValue(context) {
            try AXHelpers.HelpReadGuard.$current.withValue(outerGuard) {
                try AXHelpers.StripHelpSamples.$current.withValue(outerSamples) {
                    let states = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime,
                        readingScalarHelp: false, stoppingWhen: { false }))
                    #expect(states.first?.sendSlots?.first?.state == (failed ? .unreadable : .occupiedUnknownDestination))
                    #expect(reads.counts.first(where: { CFEqual($0.0, knob) })?.1 == 1,
                        "The required send read must sample real Help exactly once, retaining its native failure")
                    #expect(AXHelpers.HelpReadGuard.current === outerGuard)
                    #expect(AXHelpers.StripHelpSamples.current === outerSamples)
                    #expect(!outerGuard.stopped)
                }
            }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func populationClassifiersShareStatusWithoutRetryingAndNextBookendReadsAgain(failed: Bool) async throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(1_965_880)
        let insert = builder.element(1_965_881)
        let input = builder.element(1_965_882)
        let output = builder.element(1_965_883)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(insert, description: "Audio Plug-in", help: "Audio Plug-in", x: 0, y: 0, width: 60, height: 20)
        builder.setButton(input, description: "Input 1", help: "Input slot", x: 0, y: 30, width: 60, height: 20)
        builder.setButton(output, description: "Stereo Output", help: "Output slot", x: 0, y: 60, width: 60, height: 20)
        builder.setChildren(strip, [insert, input, output])
        let reads = Reads(builder: builder, input: input, failFirstInput: failed)
        let runtime = builder.makeLogicRuntime(attributeValueHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return .some(try? reads.read(element).get())
        }, attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let context = OperationTraceContext(mutationGateAcquired: true)
        OperationTraceContext.$current.withValue(context) {
            let first = AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime, stoppingWhen: { false })
            #expect(first?.count == 1)
            if failed {
                #expect(first?.first?.inputObservation?.state == .unreadable,
                    "A failed physical Help sample must not heal when another classifier asks again")
            } else {
                #expect(first?.first?.input == "Input 1")
                #expect(first?.first?.output == "Stereo Output")
                #expect(first?.first?.pluginsSource == "ax")
            }
            #expect(reads.counts.allSatisfy { $0.1 == 1 }, "Each physical Help read retains its guard, but classifiers reuse its raw sample")
            let firstCounts = reads.counts
            let second = AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime, stoppingWhen: { false })
            #expect(second?.first?.input == "Input 1", "A new independent population must sample again, not retain the earlier failure")
            #expect(firstCounts.allSatisfy { old in reads.counts.first(where: { CFEqual($0.0, old.0) })?.1 == 2 })
        }
        let beforeStandalone = reads.counts.first(where: { CFEqual($0.0, input) })?.1 ?? 0
        _ = AXLogicProElements.inputSlotRead(in: strip, runtime: runtime.ax)
        #expect((reads.counts.first(where: { CFEqual($0.0, input) })?.1 ?? 0) > beforeStandalone,
            "Standalone routing/parameter consumers remain ordinary fresh reads")
    }

    @Test(arguments: [false, true])
    func boundReadOnlyPollSharesHelpOnlyWithinOneStripAndOneCycle(failed: Bool) throws {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(1_965_900)
        let mixer = builder.element(1_965_901)
        let strip = builder.element(1_965_902)
        let insert = builder.element(1_965_903)
        let input = builder.element(1_965_904)
        let output = builder.element(1_965_905)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(mixer, kAXLayoutAreaRole as String)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(insert, description: "Audio Plug-in", help: "Audio Plug-in",
                          x: 0, y: 0, width: 60, height: 20)
        builder.setButton(input, description: "Input 1", help: "Input slot",
                          x: 0, y: 30, width: 60, height: 20)
        builder.setButton(output, description: "Stereo Output", help: "Output slot",
                          x: 0, y: 60, width: 60, height: 20)
        builder.setChildren(strip, [insert, input, output])
        builder.setChildren(mixer, [strip])
        builder.setChildren(window, [mixer])
        let reads = Reads(builder: builder, input: input, failFirstInput: failed)
        let runtime = builder.makeLogicRuntime(attributeValueHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return .some(try? reads.read(element).get())
        }, attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)

        let first = try #require(AccessibilityChannel.readChannelStrips(
            from: [strip], runtime: runtime, window: window, mixer: mixer,
            sharingHelpWithinBoundStripRead: true, stoppingWhen: { false }
        ))
        if failed {
            #expect(first.first?.inputObservation?.state == .unreadable,
                    "a failed Help sample must stay failed throughout this strip extraction")
        } else {
            #expect(first.first?.input == "Input 1")
            #expect(first.first?.output == "Stereo Output")
            #expect(first.first?.pluginsSource == "ax")
        }
        #expect(reads.counts.allSatisfy { $0.1 == 1 },
                "each physical Help element must be sampled once in the bound strip extraction")
        let firstCounts = reads.counts

        _ = AccessibilityChannel.readChannelStrips(
            from: [strip], runtime: runtime, window: window, mixer: mixer,
            sharingHelpWithinBoundStripRead: true, stoppingWhen: { false }
        )
        #expect(firstCounts.allSatisfy { old in
            reads.counts.first(where: { CFEqual($0.0, old.0) })?.1 == 2
        }, "the next poll cycle must take a fresh Help sample")
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
}
