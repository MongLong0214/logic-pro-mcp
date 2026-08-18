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
