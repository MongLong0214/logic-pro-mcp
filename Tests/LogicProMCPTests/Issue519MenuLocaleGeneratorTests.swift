import Foundation
import Testing
@testable import LogicProMCP

/// #519: ten generated AppleScript menu drives hard-coded EN/KO menu-bar/menu-item names
/// inline instead of resolving them from `AXLocalePolicy`'s `LabelSet`s, so a Logic running in
/// any other UI language (the table already carried a Japanese "File" form, for example) could
/// never reach the extra variant. These tests cover the shared generator
/// (`AppleScriptMenuResolution`) directly, then every converted call site, asserting: every
/// `LabelSet` variant is present in the emitted candidate list, canonical comes first, escaping
/// is injection-safe, and each site's pre-existing failure identifiers / Escape-on-error path
/// survived the conversion unchanged.
private final class MenuScriptProbe: @unchecked Sendable {
    private(set) var script = ""
    func capture(_ script: String) { self.script = script }
}

// MARK: - Generator unit tests

@Suite("#519 AppleScriptMenuResolution generator")
struct AppleScriptMenuResolutionGeneratorTests {
    @Test("menuBarItem emits canonical-first candidates and a distinct not-found error")
    func menuBarItemCandidateOrderAndNotFound() throws {
        let generated = AppleScriptMenuResolution.menuBarItem(
            AXLocalePolicy.navigateMenuBar,
            variableName: "barName",
            notFoundError: "NAVIGATE_MENU_BAR_NOT_FOUND"
        )
        // Derived from the LabelSet, not hardcoded. A test that spells out the whole candidate list
        // fails whenever a measured label is added — which would make adding a language a test-breaking
        // change, penalising the one thing this design exists to make cheap. Asserting the PROPERTY still
        // fails if a label is dropped or the order is wrong.
        let labels = AXLocalePolicy.navigateMenuBar.labels
        let canonical = try #require(generated.range(of: "\"\(labels[0])\""))
        for variant in labels.dropFirst() {
            let found = try #require(
                generated.range(of: "\"\(variant)\""),
                "every label in the set must reach the generated candidate list: \(variant)"
            )
            #expect(canonical.lowerBound < found.lowerBound)
        }
        let expectedList = labels.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(generated.contains("repeat with candidate in {\(expectedList)}"))
        #expect(generated.contains("if exists menu bar item candidate of menu bar 1 then"))
        #expect(generated.contains("set barName to candidate as text"))
        #expect(generated.contains("if barName is missing value then error \"NAVIGATE_MENU_BAR_NOT_FOUND\""))
    }

    @Test("menuItem nests the exists check under the given parent specifier")
    func menuItemNestsUnderParent() {
        let generated = AppleScriptMenuResolution.menuItem(
            AXLocalePolicy.goToMenuItem,
            under: "menu bar item barName of menu bar 1",
            variableName: "goToName",
            notFoundError: "GO_TO_MENU_ITEM_NOT_FOUND"
        )
        let goToLabels = AXLocalePolicy.goToMenuItem.labels.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(generated.contains("repeat with candidate in {\(goToLabels)}"))
        #expect(generated.contains(
            "if exists menu item candidate of menu 1 of menu bar item barName of menu bar 1 then"
        ))
        #expect(generated.contains("set goToName to candidate as text"))
        #expect(generated.contains("if goToName is missing value then error \"GO_TO_MENU_ITEM_NOT_FOUND\""))
    }

    @Test("every LabelSet variant is present in the emitted candidate list")
    func everyVariantPresent() {
        // transportMetronomeControl carries 6 variants — a good stress case for "every one shows up".
        let labelSet = AXLocalePolicy.transportMetronomeControl
        let generated = AppleScriptMenuResolution.candidateResolution(
            elementKeyword: "menu bar item",
            labelSet: labelSet,
            existsSuffix: " of menu bar 1",
            variableName: "x",
            notFoundError: "X_NOT_FOUND"
        )
        #expect(labelSet.labels.count > 3)
        for label in labelSet.labels {
            #expect(generated.contains("\"\(label)\""))
        }
    }

    // Mutation this rejects: dropping a variant from a LabelSet (or from the emitted candidate
    // list) silently narrows which locales a site can reach — exactly the #519 defect. Every
    // `for label in ....labels` loop in this file re-derives its expectation from the SAME
    // `AXLocalePolicy` table the generator reads, so removing a variant there fails here too
    // (see the mutation evidence in the PR description/report, not committed).
    @Test("a quote or backslash in a variant cannot break out of the candidate list literal")
    func escapingIsSafe() {
        let evil = "evil\"inject"
        let backslash = "back\\slash"
        let labelSet = AXLocalePolicy.LabelSet(
            canonical: "Safe",
            variants: [evil, backslash],
            rationale: "test fixture — not a real Logic label"
        )
        let generated = AppleScriptMenuResolution.menuBarItem(
            labelSet,
            variableName: "x",
            notFoundError: "X_NOT_FOUND"
        )
        // The escaped candidate list must read exactly as: "Safe", "evil\"inject", "back\\slash"
        // — an unescaped quote here would close the AppleScript string literal early and let the
        // remainder of the variant execute as script text instead of being treated as data.
        #expect(generated.contains("\"Safe\", \"evil\\\"inject\", \"back\\\\slash\""))
    }
}

// MARK: - Site coverage: Navigate menu (Markers, cycle-range, goto_position)

@Suite("#519 Navigate menu-drive sites route through AXLocalePolicy")
struct Issue519NavigateMenuDriveSiteTests {
    @Test("buttonWithDescription matches a button by description, not by name")
    func buttonWithDescriptionUsesTheRightSpecifier() {
        let script = AppleScriptMenuResolution.buttonWithDescription(
            AXLocalePolicy.markerListEditMenuButton,
            of: "markerGroup",
            variableName: "editButton",
            notFoundError: "MARKER_EDIT_BUTTON_NOT_FOUND"
        )
        // The whole point. `exists button candidate of markerGroup` is a BY-NAME reference, and
        // measured on a running Logic 12.3 on 2026-09-18, 412 of 439 buttons report `name` as
        // `missing value` -- a Logic toolbar button's label is its AXDescription. Asked of one
        // container both ways for the same button: by name false, by description true.
        #expect(script.contains("first button of markerGroup whose description is candidate"))
        #expect(!script.contains("exists button candidate"))

        // `whose description is` RAISES -1719 when nothing matches, so a locale that does not
        // match must not abort the script.
        #expect(script.contains("try"))
        #expect(script.contains("end try"))

        // Every label reachable, and a refusal when none is.
        for label in AXLocalePolicy.markerListEditMenuButton.labels {
            #expect(script.contains("\"\(label)\""), "missing \(label)")
        }
        #expect(script.contains("if editButton is missing value then error \"MARKER_EDIT_BUTTON_NOT_FOUND\""))
    }

    @Test("buttonWithDescription escapes a quote or backslash inside its candidate list")
    func buttonWithDescriptionEscapesSafely() {
        let hostile = AXLocalePolicy.LabelSet(
            canonical: "plain",
            variants: ["has \"quote\"", "has \\ backslash"],
            rationale: "test fixture"
        )
        let script = AppleScriptMenuResolution.buttonWithDescription(
            hostile, of: "someGroup", variableName: "b", notFoundError: "NOPE"
        )
        for label in hostile.labels {
            #expect(script.contains(AppleScriptSafety.escapeForScript(label)))
        }
        #expect(!script.contains("{\"has \"quote\""))
    }

    @Test("Open Marker List script resolves the Navigate bar/item from LabelSets and keeps the Escape-on-error path")
    func markerOpenListScript() {
        let script = AccessibilityChannel.markerMenuActuationScript(.openList)
        for label in AXLocalePolicy.navigateMenuBar.labels {
            #expect(script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.openMarkerListMenuItem.labels {
            #expect(script.contains("\"\(label)\""))
        }
        // #346: the Escape-on-error path (key code 53) must survive the conversion unchanged.
        #expect(script.contains("key code 53"))
        // No literal-name click anywhere — actuation goes through the resolved variable only.
        #expect(!script.contains("menu bar item \"Navigate\""))
        #expect(!script.contains("menu bar item \"탐색\""))
    }

    @Test("Create Marker script resolves the Navigate bar/item from LabelSets and keeps the Escape-on-error path")
    func markerCreateScript() {
        let script = AccessibilityChannel.markerMenuActuationScript(.create)
        for label in AXLocalePolicy.navigateMenuBar.labels {
            #expect(script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.createMarkerMenuItem.labels {
            #expect(script.contains("\"\(label)\""))
        }
        #expect(script.contains("key code 53"))
    }

    @Test("cycle-range Set Locators script resolves the Navigate bar/item from LabelSets")
    func cycleRangeLocatorScriptCoversVariants() {
        let script = AccessibilityChannel.cycleRangeLocatorScript(startPos: "1 1 1 1", endPos: "9 1 1 1")
        for label in AXLocalePolicy.navigateMenuBar.labels {
            #expect(script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.setLocatorsMenuItem.labels {
            #expect(script.contains("\"\(label)\""))
        }
        // The pre-existing failure sentinel the caller pattern-matches on must be unchanged.
        #expect(script.contains("return \"no-menu\""))
    }

    @Test("goto_position script resolves Navigate > Go To > Position… from LabelSets")
    func gotoPositionScriptCoversVariants() {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 519)
        for label in AXLocalePolicy.navigateMenuBar.labels {
            #expect(script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.goToMenuItem.labels {
            #expect(script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.goToPositionMenuItem.labels {
            #expect(script.contains("\"\(label)\""))
        }
    }
}

// MARK: - Site coverage: File menu (Bounce, MIDI import)

@Suite("#519 File menu-drive sites route through AXLocalePolicy")
struct Issue519FileMenuDriveSiteTests {
    @Test("the secondary MIDI import traversal uses the existing localized panel and commit names")
    func midiImportSecondaryTraversalUsesLocalizedNames() async throws {
        let path = NSTemporaryDirectory() + "issue904-\(UUID().uuidString).mid"
        FileManager.default.createFile(atPath: path, contents: Data([0x4D, 0x54, 0x68, 0x64]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = MenuScriptProbe()
        _ = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true }, path: path,
            executeScript: { script in
                probe.capture(script)
                return .success(#"{"result":"MENU_ERROR: not found"}"#)
            }, trackCount: { 0 }, trackNames: { [] },
            regionInfos: { .success([], complete: false) }, deltaPoll: {})
        let start = try #require(probe.script.range(of: "if importClicked is false then"))
        let end = try #require(probe.script.range(of: "if importClicked then exit repeat", range: start.upperBound..<probe.script.endIndex))
        let secondary = String(probe.script[start.upperBound..<end.lowerBound])
        // Actual emitted script only; the injected executor never runs System Events.
        // The same existing German panel/button row is needed by the secondary path.
        #expect(secondary.contains("\"Importieren\""))
        #expect(!secondary.contains("first window whose name is \"Import\""))
        #expect(!secondary.contains("button \"Import\" of"))
        #expect(secondary.contains("enabled of ib"))
    }

    @Test("File > Bounce script resolves File/Bounce from LabelSets, reaching the already-recorded Japanese File variant")
    func bounceMenuScriptCoversVariants() async {
        let probe = MenuScriptProbe()
        _ = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { true },
            executeScript: { script in
                probe.capture(script)
                return .success(#"{"result":"BOUNCE_MENU_ITEM_NOT_FOUND"}"#)
            }
        )
        for label in AXLocalePolicy.fileMenuBar.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.bounceMenuItem.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.projectOrSectionMenuItem.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        // The headline #519 claim: fileMenuBar's Japanese "ファイル" was already in the table and
        // is now actually reachable from the generated script, not just recorded.
        #expect(probe.script.contains("\"ファイル\""))
        // The pre-existing terminal failure identifier consumers pattern-match on is unchanged
        // (see Issue256BounceMenuTests "missing native menu item returns a targeted terminal failure").
        #expect(probe.script.contains("BOUNCE_MENU_ITEM_NOT_FOUND"))
    }

    @Test("the Bounce dialog poll tests the title against every label, not against an EN/KO pair")
    func bounceDialogPollCoversVariants() async {
        let probe = MenuScriptProbe()
        _ = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { true },
            executeScript: { script in
                probe.capture(script)
                return .success(#"{"result":"BOUNCE_MENU_ITEM_NOT_FOUND"}"#)
            }
        )
        // Asserting that the labels appear ANYWHERE in the script would pass even if the poll
        // were reverted to `contains "Bounce" or contains "바운스"`, because the same labels are
        // already in the menu-item resolution further up. So this reads the poll's own block and
        // nothing else: from where `bounceSeen` is initialised to the `end repeat` that closes it.
        let start = probe.script.range(of: "set bounceSeen to false")
        #expect(start != nil, "the dialog poll must be generated, not hand-written")
        guard let start else { return }
        let rest = probe.script[start.lowerBound...]
        guard let end = rest.range(of: "end repeat") else {
            #expect(Bool(false), "the generated poll must close its repeat")
            return
        }
        let block = String(rest[..<end.upperBound])
        for label in AXLocalePolicy.bounceMenuItem.labels {
            #expect(block.contains("\"\(label)\""), "poll is missing \(label)")
        }
        #expect(block.contains("bounceName contains (candidate as text)"))
        // The branch must read the boolean the block sets, or the block is decoration.
        #expect(probe.script.contains("if bounceSeen then"))
        #expect(!probe.script.contains("bounceName contains \"Bounce\""))
    }

    @Test("textContainsAny escapes a quote or backslash inside its candidate list")
    func textContainsAnyEscapesSafely() {
        let hostile = AXLocalePolicy.LabelSet(
            canonical: "plain",
            variants: ["has \"quote\"", "has \\ backslash"],
            rationale: "test fixture"
        )
        let script = AppleScriptMenuResolution.textContainsAny(
            hostile, of: "someName", variableName: "seen"
        )
        #expect(script.contains("set seen to false"))
        #expect(script.contains("if someName contains (candidate as text) then"))
        for label in hostile.labels {
            #expect(script.contains(AppleScriptSafety.escapeForScript(label)))
        }
        // The escaped forms must not re-introduce a bare quote that closes the list literal early.
        #expect(!script.contains("{\"has \"quote\""))
    }

    @Test("File > Import > MIDI File… script resolves File/Import/MIDI File from LabelSets, reaching the Japanese File variant")
    func midiImportScriptCoversVariants() async {
        let path = NSTemporaryDirectory() + "issue519-\(UUID().uuidString).mid"
        FileManager.default.createFile(atPath: path, contents: Data([0x4D, 0x54, 0x68, 0x64]))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let probe = MenuScriptProbe()
        _ = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: path,
            executeScript: { script in
                probe.capture(script)
                return .success(#"{"result":"MENU_ERROR: not found"}"#)
            },
            trackCount: { 0 },
            trackNames: { [] },
            regionInfos: { .success([], complete: false) },
            deltaPoll: {}
        )
        for label in AXLocalePolicy.fileMenuBar.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.importMenuItem.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.midiFileMenuItem.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        #expect(probe.script.contains("\"ファイル\""))
        // The pre-existing "MENU_ERROR: " prefix the Swift caller pattern-matches on is unchanged.
        #expect(probe.script.contains("MENU_ERROR"))
    }
}

// MARK: - Site coverage: Edit menu (region move-to-playhead)

@Suite("#519 Edit menu-drive site routes through AXLocalePolicy")
struct Issue519EditMenuDriveSiteTests {
    @Test("Edit > Move > To Playhead script resolves Edit/Move/To Playhead from LabelSets")
    func moveToPlayheadScriptCoversVariants() async {
        let builder = FakeAXRuntimeBuilder()
        let runtime = builder.makeLogicRuntime()
        let probe = MenuScriptProbe()
        _ = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
            runtime: runtime,
            executeScript: { script in
                probe.capture(script)
                return .success("MENU_ERROR: not found")
            },
            settle: {}
        )
        for label in AXLocalePolicy.editMenuBar.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.moveMenuItem.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        for label in AXLocalePolicy.toPlayheadMenuItem.labels {
            #expect(probe.script.contains("\"\(label)\""))
        }
        // The pre-existing "MENU_ERROR: " prefix the Swift caller pattern-matches on is unchanged.
        #expect(probe.script.contains("MENU_ERROR"))
    }
}
