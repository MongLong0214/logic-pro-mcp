@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Suite struct MIDIKeyCommandAXSurfaceTests {
    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let window: AXUIElement
        let command: AXUIElement
        let assignment: AXUIElement
        let labels: MIDIKeyCommandSurfaceResolver.Labels
        let runtime: AXHelpers.Runtime
    }

    private func fixture(
        failWindowChildren: Bool = false,
        failSearchSubrole: Bool = false
    ) -> Fixture {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(1)
        let header = builder.element(2)
        let search = builder.element(3)
        let command = builder.element(4)
        let assignment = builder.element(5)

        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(header, kAXStaticTextRole as String)
        builder.setAttribute(header, kAXValueAttribute as String, "Control Surface")
        builder.setFrame(header, x: 500, y: 100, width: 180, height: 18)

        builder.setRole(search, kAXTextFieldRole as String)
        builder.setAttribute(search, kAXSubroleAttribute as String, kAXSearchFieldSubrole as String)
        builder.setAttribute(search, kAXValueAttribute as String, "Toggle Metronome Click")
        builder.setFrame(search, x: 20, y: 140, width: 360, height: 18)

        builder.setRole(command, kAXTextFieldRole as String)
        builder.setAttribute(command, kAXValueAttribute as String, "Toggle Metronome Click")
        builder.setFrame(command, x: 20, y: 220, width: 360, height: 18)

        builder.setRole(assignment, kAXStaticTextRole as String)
        builder.setAttribute(assignment, kAXValueAttribute as String, "CC 98 (127)")
        builder.setFrame(assignment, x: 500, y: 220, width: 180, height: 18)
        builder.setChildren(window, [header, search, command, assignment])

        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                guard failSearchSubrole,
                      CFEqual(element, search),
                      attribute == (kAXSubroleAttribute as String) else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            },
            childrenResultHandler: { element in
                guard failWindowChildren, CFEqual(element, window) else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        return Fixture(
            builder: builder,
            window: window,
            command: command,
            assignment: assignment,
            labels: .init(
                commandNames: ["Toggle Metronome Click"],
                controlSurfaceColumnTitles: ["Control Surface"]
            ),
            runtime: runtime
        )
    }

    @Test func resolvesElementsFromCompleteFilteredSurfaceWithoutMutation() throws {
        let fixture = fixture()
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandAXSurface.read(
            in: fixture.window,
            entry: entry,
            labels: fixture.labels,
            runtime: fixture.runtime
        )

        guard case .resolved(let command, let assignment, let observation) = outcome else {
            Issue.record("expected resolved surface; got \(outcome)")
            return
        }
        #expect(CFEqual(command, fixture.command))
        #expect(CFEqual(assignment, fixture.assignment))
        #expect(observation == .matchingLabelUnverifiedSource(.init(cc: 98, value: 127)))
        #expect(fixture.builder.setCalls.isEmpty)
        #expect(fixture.builder.actionCalls.isEmpty)
    }

    @Test func nonDefinitiveChildrenFailureIsNotFlattenedToEmpty() throws {
        let fixture = fixture(failWindowChildren: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandAXSurface.read(
            in: fixture.window,
            entry: entry,
            labels: fixture.labels,
            runtime: fixture.runtime
        )

        #expect(outcome.isUnreadableSurface)
    }

    @Test func boundedTraversalCannotPublishAResolutionFromAPrefix() throws {
        let fixture = fixture()
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandAXSurface.read(
            in: fixture.window,
            entry: entry,
            labels: fixture.labels,
            runtime: fixture.runtime,
            maxNodes: 2
        )

        #expect(outcome.isScanIncomplete)
    }

    @Test func assignmentGeometryMustBeReadableBeforeUniquenessCanBeClaimed() throws {
        let fixture = fixture()
        fixture.builder.removeAttribute(fixture.assignment, kAXPositionAttribute as String)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandAXSurface.read(
            in: fixture.window,
            entry: entry,
            labels: fixture.labels,
            runtime: fixture.runtime
        )

        #expect(outcome.isUnreadableSurface)
    }

    @Test func unreadableSearchSubroleCannotBecomeACommandCandidate() throws {
        let fixture = fixture(failSearchSubrole: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandAXSurface.read(
            in: fixture.window,
            entry: entry,
            labels: fixture.labels,
            runtime: fixture.runtime
        )

        #expect(outcome.isUnreadableSurface)
    }
}
