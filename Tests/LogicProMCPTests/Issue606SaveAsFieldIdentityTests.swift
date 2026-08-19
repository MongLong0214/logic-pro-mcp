import ApplicationServices
import Testing
@testable import LogicProMCP

/// #606: the Save panel's filename field is identified by FOCUS, not by `AXDescription`.
///
/// The shipped rule asked for `AXDescription == "text field"` and matched nothing on the live panel,
/// which read as "this panel has no filename field" and sent three investigations at the classifier.
/// The rule had been written from an AppleScript probe: System Events *synthesises* `description`
/// from `AXRoleDescription` when `AXDescription` is nil, and the raw API this code uses does not.
/// Measured on the live panel:
///
///     field           SysEv description     AXDescription   AXRoleDescription     AXFocused
///     search          "search text field"   nil             "search text field"   false
///     FILENAME        "text field"          nil             "text field"          true
///     tag editor      "tag editor"          "tag editor"    "text field"          false
@Suite(.serialized)
struct Issue606SaveAsFieldIdentityTests {
    /// Builds the measured shape of Logic's Save panel: a split group holding the three text fields
    /// exactly as the live panel exposes them.
    private func makeLivePanelShape() -> (FakeAXRuntimeBuilder, AXUIElement) {
        let b = FakeAXRuntimeBuilder()
        let panel = b.element(1)
        let splitGroup = b.element(2)
        let search = b.element(3)
        let filename = b.element(4)
        let tagEditor = b.element(5)

        b.setAttribute(panel, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(panel, kAXTitleAttribute as String, "Save")
        b.setChildren(panel, [splitGroup])
        b.setAttribute(splitGroup, kAXRoleAttribute as String, kAXSplitGroupRole as String)
        b.setChildren(splitGroup, [search, filename, tagEditor])

        for field in [search, filename, tagEditor] {
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setChildren(field, [])
        }
        // Exactly as measured: AXDescription is nil on the two the old rule needed to tell apart,
        // and present on the one it did not.
        b.setAttribute(search, kAXFocusedAttribute as String, false)
        b.setAttribute(filename, kAXFocusedAttribute as String, true)
        b.setAttribute(filename, kAXValueAttribute as String, "Untitled")
        b.setAttribute(tagEditor, kAXDescriptionAttribute as String, "tag editor")
        b.setAttribute(tagEditor, kAXFocusedAttribute as String, false)
        return (b, panel)
    }

    @Test("issue606_the_filename_field_is_the_focused_one")
    func filenameFieldIsTheFocusedOne() throws {
        let (builder, panel) = makeLivePanelShape()
        let runtime = builder.makeLogicRuntime()

        let fields = AccessibilityChannel.filenameFieldCandidates(in: panel, runtime: runtime)
        #expect(fields.count == 1)

        let field = try #require(fields.first)
        let value: String? = AXHelpers.getAttribute(
            field, kAXValueAttribute as String, runtime: runtime.ax
        )
        let readBack = try #require(value)
        #expect(readBack == "Untitled")
    }

    /// The old rule, run against the same shape, to pin WHY it failed rather than only that it did.
    @Test("issue606_the_old_description_rule_matches_nothing_on_this_shape")
    func oldDescriptionRuleMatchesNothing() {
        let (builder, panel) = makeLivePanelShape()
        let runtime = builder.makeLogicRuntime()

        let byDescription = AXHelpers.findAllDescendants(
            of: panel, role: kAXTextFieldRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getDescription($0, runtime: runtime.ax) == "text field" }

        // Zero — not one. This is the whole failure: a panel with a perfectly readable filename field
        // reported as having none, because the attribute the filter reads is empty on that element.
        #expect(byDescription.isEmpty)
    }

    /// Focus must select, not merely exist: a panel where nothing is focused resolves nothing, and a
    /// panel where two fields claim focus is ambiguous and must not be typed into.
    @Test("issue606_focus_rule_refuses_when_it_does_not_select_exactly_one")
    func focusRuleRefusesAmbiguity() {
        let (builder, panel) = makeLivePanelShape()
        let runtime = builder.makeLogicRuntime()

        builder.setAttribute(builder.element(4), kAXFocusedAttribute as String, false)
        #expect(AccessibilityChannel.filenameFieldCandidates(in: panel, runtime: runtime).isEmpty)

        builder.setAttribute(builder.element(4), kAXFocusedAttribute as String, true)
        builder.setAttribute(builder.element(3), kAXFocusedAttribute as String, true)
        #expect(AccessibilityChannel.filenameFieldCandidates(in: panel, runtime: runtime).count == 2)
    }
}

/// #606 follow-up: the menu gate must refuse an UNREADABLE `AXEnabled`, not only a false one.
///
/// The first cut used `enabled != false`, so a missing read was treated as permission to press. That
/// is the opposite of this tree's other actuation gate (`menuItemEnabledForActuation` is
/// `enabled == true`), and it leaves open exactly the hole the gate exists to close: `AXPress` on a
/// disabled item returns true, so an unreadable answer followed by a press is indistinguishable from
/// success on a disabled item.
@Suite(.serialized)
struct Issue606MenuEnabledGateTests {
    private func gateAccepts(enabled: Bool?) -> Bool {
        // The predicate under test, stated the way the call site states it.
        enabled == true
    }

    @Test("issue606_menu_gate_accepts_only_a_read_true")
    func gateAcceptsOnlyReadTrue() {
        #expect(gateAccepts(enabled: true))
        #expect(!gateAccepts(enabled: false))
        // The case the first cut got wrong.
        #expect(!gateAccepts(enabled: nil))
    }

    /// The same predicate, read out of the shipped source, so this test fails if the call site drifts
    /// back to the lenient form while the helper above stays strict.
    @Test("issue606_the_shipped_call_site_uses_the_strict_form")
    func shippedCallSiteIsStrict() throws {
        let source = try String(
            contentsOfFile: #filePath
                .replacingOccurrences(
                    of: "Tests/LogicProMCPTests/Issue606SaveAsFieldIdentityTests.swift",
                    with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Project.swift"
                ),
            encoding: .utf8
        )
        let usesStrictForm = source.contains("guard enabled == true else {")
        let usesLenientForm = source.contains("guard enabled != false else {")
        #expect(usesStrictForm)
        #expect(!usesLenientForm)
    }
}

/// #519: the Save As menu drive must resolve through AXLocalePolicy, not through two hard-coded
/// literals. The pair it replaced covered exactly two of the languages Logic ships.
@Suite(.serialized)
struct Issue519SaveAsMenuLocaleTests {
    @Test("issue519_save_as_labels_cover_the_measured_forms")
    func labelsCoverMeasuredForms() {
        let labels = AXLocalePolicy.saveAsMenuItem.labels
        #expect(labels.contains("Save As…"))
        #expect(labels.contains("다른 이름으로 저장…"))
        // The trailing character is a real ellipsis. Three dots is a different string and would not
        // match the live menu.
        #expect(!labels.contains("Save As..."))
    }

    /// The item is picked by exact label, so the two neighbours in the same File menu — measured on a
    /// live Logic 12.3 two rows away — must not match.
    @Test("issue519_save_as_does_not_match_its_neighbours_in_the_same_menu")
    func doesNotMatchNeighbours() {
        let item = AXLocalePolicy.saveAsMenuItem
        #expect(item.matches("Save As…"))
        #expect(!item.matches("Save A Copy As…"))
        #expect(!item.matches("Save as Template…"))
        #expect(!item.matches("Save"))
    }

    /// The bar it hangs off already carries a Japanese form that the old literal pair could not reach.
    @Test("issue519_the_file_menu_bar_reaches_beyond_the_two_old_literals")
    func fileMenuBarReachesFurther() {
        let bar = AXLocalePolicy.fileMenuBar.labels
        #expect(bar.contains("File"))
        #expect(bar.contains("파일"))
        // The label the replaced pair could never have matched.
        #expect(bar.contains("ファイル"))
    }

    /// The shipped call site must not have drifted back to literals — the defect #519 is about is a
    /// literal in a call site, not a missing label set.
    @Test("issue519_the_shipped_call_site_uses_the_label_sets")
    func shippedCallSiteIsLocaleResolved() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/LogicProMCPTests/Issue606SaveAsFieldIdentityTests.swift",
                with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Project.swift"
            ),
            encoding: .utf8
        )
        let usesLabelSets = source.contains(
            "clickMenuItem(\n            AXLocalePolicy.saveAsMenuItem, in: AXLocalePolicy.fileMenuBar"
        )
        let usesKoreanLiteral = source.contains("menuName: \"파일\"")
        let usesEnglishLiteral = source.contains("menuName: \"File\"")
        #expect(usesLabelSets)
        #expect(!usesKoreanLiteral)
        #expect(!usesEnglishLiteral)
    }
}

/// #519: the Track menu bar's three measured spellings moved out of a literal array in
/// `clickTrackMenu` and into `AXLocalePolicy`. The move must not lose any of them — the Japanese form
/// in particular was measured on a Japanese Logic and its absence made every menu-driven track
/// operation return `element_not_found` there.
extension Issue519SaveAsMenuLocaleTests {
    @Test("issue519_the_track_menu_bar_keeps_all_three_measured_spellings")
    func trackMenuBarKeepsAllSpellings() {
        let labels = AXLocalePolicy.trackMenuBar.labels
        #expect(labels.contains("Track"))
        #expect(labels.contains("트랙"))
        #expect(labels.contains("トラック"))
    }

    /// The literal array must not have grown back. A fourth language belongs in the label set.
    @Test("issue519_the_track_menu_drive_does_not_hard_code_a_spelling")
    func trackMenuDriveHasNoLiteralSpelling() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/LogicProMCPTests/Issue606SaveAsFieldIdentityTests.swift",
                with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Tracks.swift"
            ),
            encoding: .utf8
        )
        let usesPolicy = source.contains("AXLocalePolicy.trackMenuBar.labels")
        let hardCodesJapanese = source.contains("[menuName, englishMenuName, \"トラック\"]")
        #expect(usesPolicy)
        #expect(!hardCodesJapanese)
    }
}
