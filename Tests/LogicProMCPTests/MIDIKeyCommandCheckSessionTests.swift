@preconcurrency import ApplicationServices
import CoreGraphics
import Testing
@testable import LogicProMCP

@Suite struct MIDIKeyCommandCheckSessionTests {
    private final class Probe: @unchecked Sendable {
        var activated = 0
        var optionKPosts = 0
        var typed: [String] = []
        var closePresses = 0
        var ownsGate = true
        var frontmost = true
    }

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let window: AXUIElement
        let probe: Probe
        let runtime: MIDIKeyCommandCheckSession.Runtime
    }

    private func fixture(
        windowInitiallyOpen: Bool = false,
        uiLocale: String? = "en-US",
        frontmost: Bool = true,
        closeSucceeds: Bool = true,
        loseOwnershipAfterTyping: Bool = false,
        titleReadFails: Bool = false,
        titleIsMalformed: Bool = false,
        windowAppearsDuringActivation: Bool = false,
        ambiguousWindowsAfterPost: Bool = false,
        reusesBaselineWindowAfterPost: Bool = false,
        refreshesBaselineWindowWrapperAfterPost: Bool = false,
        closeLeavesWindowWithDifferentTitle: Bool = false,
        matchingAssignment: String = "CC 98 (127)"
    ) -> Fixture {
        let builder = FakeAXRuntimeBuilder()
        let probe = Probe()
        probe.frontmost = frontmost
        let app = builder.element(1)
        let window = builder.element(2)
        let close = builder.element(3)
        let search = builder.element(4)
        let header = builder.element(5)
        let command = builder.element(6)
        let assignment = builder.element(7)
        let competingWindow = builder.element(8)
        let refreshedWindow = AXUIElementCreateApplication(pid_t(1002))

        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(
            window,
            kAXTitleAttribute as String,
            titleIsMalformed ? 42
                : (refreshesBaselineWindowWrapperAfterPost
                    ? "Other Window"
                    : "Key Command Assignments – U.S.")
        )
        builder.setAttribute(window, "AXCloseButton", close)
        builder.setRole(close, kAXButtonRole as String)
        builder.setRole(competingWindow, kAXWindowRole as String)
        builder.setAttribute(
            competingWindow,
            kAXTitleAttribute as String,
            "Other Window"
        )
        builder.setRole(refreshedWindow, kAXWindowRole as String)
        builder.setAttribute(
            refreshedWindow,
            kAXTitleAttribute as String,
            "Key Command Assignments – Refreshed Wrapper"
        )

        builder.setRole(search, kAXTextFieldRole as String)
        builder.setAttribute(search, kAXSubroleAttribute as String, kAXSearchFieldSubrole as String)
        builder.setAttribute(search, kAXValueAttribute as String, "")
        builder.setAttribute(search, kAXFocusedAttribute as String, false)

        builder.setRole(header, kAXStaticTextRole as String)
        builder.setAttribute(header, kAXValueAttribute as String, "Control Surface")
        builder.setFrame(header, x: 500, y: 100, width: 180, height: 18)

        builder.setRole(command, kAXTextFieldRole as String)
        builder.setAttribute(command, kAXValueAttribute as String, "Toggle Metronome Click")
        builder.setFrame(command, x: 20, y: 220, width: 360, height: 18)

        builder.setRole(assignment, kAXStaticTextRole as String)
        builder.setAttribute(assignment, kAXValueAttribute as String, matchingAssignment)
        builder.setFrame(assignment, x: 500, y: 220, width: 180, height: 18)

        builder.setChildren(window, [search])
        builder.setAttribute(
            app,
            kAXWindowsAttribute as String,
            windowInitiallyOpen ? [window]
                : ((reusesBaselineWindowAfterPost || refreshesBaselineWindowWrapperAfterPost)
                    ? [refreshesBaselineWindowWrapperAfterPost ? window : competingWindow]
                    : [AXUIElement]())
        )

        let ax = builder.makeAXRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard titleReadFails,
                      CFEqual(element, window),
                      attribute == (kAXTitleAttribute as String) else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: { element, attribute, value in
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, action in
                guard CFEqual(element, close), action == (kAXPressAction as String) else { return true }
                probe.closePresses += 1
                if closeLeavesWindowWithDifferentTitle {
                    builder.setAttribute(window, kAXTitleAttribute as String, "Other Window")
                    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
                } else if closeSucceeds {
                    builder.setAttribute(app, kAXWindowsAttribute as String, [AXUIElement]())
                }
                return true
            }
        )
        let elements = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax)
        let runtime = MIDIKeyCommandCheckSession.Runtime(
            activateLogic: {
                probe.activated += 1
                if windowAppearsDuringActivation {
                    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
                }
            },
            logicIsFrontmost: { probe.frontmost },
            postOptionK: {
                probe.optionKPosts += 1
                if ambiguousWindowsAfterPost || reusesBaselineWindowAfterPost {
                    builder.setAttribute(
                        competingWindow,
                        kAXTitleAttribute as String,
                        "Key Command Assignments – Competing"
                    )
                }
                builder.setAttribute(
                    app,
                    kAXWindowsAttribute as String,
                    ambiguousWindowsAfterPost ? [window, competingWindow]
                        : (reusesBaselineWindowAfterPost ? [competingWindow]
                            : (refreshesBaselineWindowWrapperAfterPost ? [refreshedWindow] : [window]))
                )
                return true
            },
            typeText: { text in
                probe.typed.append(text)
                builder.setAttribute(search, kAXValueAttribute as String, text)
                builder.setChildren(window, [search, header, command, assignment])
                if loseOwnershipAfterTyping { probe.ownsGate = false }
                return true
            },
            sleep: { _ in },
            isCancelled: { false },
            ownsGate: { probe.ownsGate },
            uiLocale: { uiLocale },
            ax: ax,
            elements: elements
        )
        return Fixture(builder: builder, app: app, window: window, probe: probe, runtime: runtime)
    }

    @Test func checkOpensFreshWindowTypesLocaleQueryReadsExactAssignmentAndCloses() throws {
        let fixture = fixture()
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .inspected(.matchingLabelUnverifiedSource))
        #expect(fixture.probe.activated == 1)
        #expect(fixture.probe.optionKPosts == 1)
        #expect(fixture.probe.typed == ["Toggle Metronome Click"])
        #expect(fixture.probe.closePresses == 1)
    }

    @Test func preExistingKeyCommandsWindowIsNeverFilteredOrClosed() throws {
        let fixture = fixture(windowInitiallyOpen: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "key_commands_in_use", cleanupConfirmed: true))
        #expect(fixture.probe.activated == 0)
        #expect(fixture.probe.optionKPosts == 0)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func unsupportedLocaleRefusesBeforeActivationOrKeyPost() throws {
        let fixture = fixture(uiLocale: "nl-NL")
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "command_name_unknown_for_locale", cleanupConfirmed: true))
        #expect(fixture.probe.activated == 0)
        #expect(fixture.probe.optionKPosts == 0)
        #expect(fixture.probe.typed.isEmpty)
    }

    @Test func unreadableExistingWindowTitleFailsClosedBeforeAnyInput() throws {
        let fixture = fixture(windowInitiallyOpen: true, titleReadFails: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "key_commands_window_unreadable", cleanupConfirmed: true))
        #expect(fixture.probe.activated == 0)
        #expect(fixture.probe.optionKPosts == 0)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func malformedExistingWindowTitleFailsClosedBeforeAnyInput() throws {
        let fixture = fixture(windowInitiallyOpen: true, titleIsMalformed: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "key_commands_window_unreadable", cleanupConfirmed: true))
        #expect(fixture.probe.activated == 0)
        #expect(fixture.probe.optionKPosts == 0)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func windowAppearingDuringActivationIsNotToggledOrAdopted() throws {
        let fixture = fixture(windowAppearsDuringActivation: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "key_commands_in_use", cleanupConfirmed: true))
        #expect(fixture.probe.activated == 1)
        #expect(fixture.probe.optionKPosts == 0)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func multiplePostKeyCandidatesAreNeverFilteredOrClosed() throws {
        let fixture = fixture(ambiguousWindowsAfterPost: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "key_commands_window_ambiguous", cleanupConfirmed: false))
        #expect(fixture.probe.optionKPosts == 1)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func postKeyCandidateMustHaveANewWindowIdentity() throws {
        let fixture = fixture(reusesBaselineWindowAfterPost: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(
            stage: "key_commands_window_identity_mismatch",
            cleanupConfirmed: false
        ))
        #expect(fixture.probe.optionKPosts == 1)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func equivalentRefreshedWrapperCannotMakeABaselineWindowLookNew() throws {
        let fixture = fixture(refreshesBaselineWindowWrapperAfterPost: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(
            stage: "key_commands_window_identity_mismatch",
            cleanupConfirmed: false
        ))
        #expect(fixture.probe.optionKPosts == 1)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 0)
    }

    @Test func missingPositiveFocusProofPostsNoQueryAndClosesOwnedWindow() throws {
        let fixture = fixture(frontmost: false)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "search_focus", cleanupConfirmed: true))
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.closePresses == 1)
    }

    @Test func failedCloseCannotPublishAnInspection() throws {
        let fixture = fixture(closeSucceeds: false)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "close_key_commands", cleanupConfirmed: false))
        #expect(fixture.probe.typed == ["Toggle Metronome Click"])
        #expect(fixture.probe.closePresses == 1)
    }

    @Test func titleChangeCannotMakeAStillPresentOwnedWindowLookClosed() throws {
        let fixture = fixture(closeLeavesWindowWithDifferentTitle: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "close_key_commands", cleanupConfirmed: false))
        #expect(fixture.probe.typed == ["Toggle Metronome Click"])
        #expect(fixture.probe.closePresses == 1)
    }

    @Test func matchingLabelRemainsSourceUnverified() throws {
        let fixture = fixture(matchingAssignment: "CC 98 (127)")
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .inspected(.matchingLabelUnverifiedSource))
    }

    @Test func ownershipLossAfterTypingDoesNotPerformAnUnauthorizedClose() throws {
        let fixture = fixture(loseOwnershipAfterTyping: true)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .failed(stage: "ownership_lost", cleanupConfirmed: false))
        #expect(fixture.probe.typed == ["Toggle Metronome Click"])
        #expect(fixture.probe.closePresses == 0)
    }

    @Test(arguments: [
        ("", MIDIKeyCommandSetup.Inspection.missing),
        ("1", MIDIKeyCommandSetup.Inspection.provisional),
        ("CC 97 (127)", MIDIKeyCommandSetup.Inspection.conflicting),
    ])
    func mapsVisibleAssignmentStatesWithoutPromotingReadiness(
        raw: String,
        expected: MIDIKeyCommandSetup.Inspection
    ) throws {
        let fixture = fixture(matchingAssignment: raw)
        let entry = try #require(MIDIKeyCommandBindingCatalog.entries.first)

        let outcome = MIDIKeyCommandCheckSession.inspect(entry: entry, runtime: fixture.runtime)

        #expect(outcome == .inspected(expected))
    }
}
