import CoreGraphics
import Testing
@testable import LogicProMCP

@Suite struct MIDIKeyCommandSurfaceResolverTests {
    private func cell(
        _ id: Int,
        _ role: MIDIKeyCommandSurfaceResolver.Cell.Role,
        _ text: String?,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 180,
        height: CGFloat = 18
    ) -> MIDIKeyCommandSurfaceResolver.Cell {
        .init(
            id: id,
            role: role,
            text: text,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private static let entry = MIDIKeyCommandBindingCatalog.entries[0]
    private static let englishLabels = MIDIKeyCommandSurfaceResolver.Labels(
        commandNames: [entry.commandName],
        controlSurfaceColumnTitles: ["Control Surface"]
    )

    private func resolve(
        _ cells: [MIDIKeyCommandSurfaceResolver.Cell],
        labels: MIDIKeyCommandSurfaceResolver.Labels = Self.englishLabels
    ) -> MIDIKeyCommandSurfaceResolver.Resolution {
        MIDIKeyCommandSurfaceResolver.resolve(entry: Self.entry, labels: labels, cells: cells)
    }

    @Test func resolvesExactCommandAndSameRowControlSurfaceCell() {
        let cells = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .searchField, Self.entry.commandName, x: 20, y: 130),
            cell(3, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(4, .staticText, "CC 98 (127)", x: 500, y: 220),
            cell(5, .staticText, "CC 20 (1)", x: 500, y: 260),
        ]

        #expect(resolve(cells) == .resolved(
            commandCellID: 3,
            assignmentCellID: 4,
            observation: .matchingLabelUnverifiedSource(.init(cc: 98, value: 127))
        ))
    }

    @Test func retainsProvisionalAssignmentAsUnverified() {
        let cells = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(3, .staticText, "1", x: 500, y: 220),
        ]

        #expect(resolve(cells) == .resolved(
            commandCellID: 2,
            assignmentCellID: 3,
            observation: .provisional(raw: "1")
        ))
    }

    @Test func emptySameRowAssignmentIsMissing() {
        let cells = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(3, .staticText, "", x: 500, y: 220),
        ]

        #expect(resolve(cells) == .resolved(
            commandCellID: 2,
            assignmentCellID: 3,
            observation: .missing
        ))
    }

    @Test func rejectsSubstringAndDuplicateExactCommands() {
        let base = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .textField, "Toggle Metronome Click Settings", x: 20, y: 180, width: 360),
            cell(3, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(4, .staticText, "CC 98 (127)", x: 500, y: 220),
        ]
        #expect(resolve(base).isResolved)

        let duplicate = base + [cell(5, .textField, "\(Self.entry.commandName) *", x: 20, y: 260, width: 360)]
        #expect(resolve(duplicate) == .ambiguousCommand)
    }

    @Test func rejectsAmbiguousSameRowAssignments() {
        let cells = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(3, .staticText, "CC 98 (127)", x: 500, y: 220),
            cell(4, .staticText, "CC 98 (127)", x: 510, y: 220),
        ]

        #expect(resolve(cells) == .ambiguousAssignment)
    }

    @Test func refusesMissingOrAmbiguousColumnAnchor() {
        let row: [MIDIKeyCommandSurfaceResolver.Cell] = [
            cell(2, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(3, .staticText, "CC 98 (127)", x: 500, y: 220),
        ]
        #expect(resolve(row) == .columnUnavailable)

        let headers: [MIDIKeyCommandSurfaceResolver.Cell] = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(4, .staticText, "Control Surface", x: 700, y: 100),
        ]
        #expect(resolve(headers + row) == .columnUnavailable)
    }

    @Test func refusesWrongRowWrongColumnAndUnreadableGeometry() {
        let base = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(3, .staticText, "CC 98 (127)", x: 500, y: 260),
            cell(4, .staticText, "CC 98 (127)", x: 760, y: 220),
        ]
        #expect(resolve(base) == .assignmentUnavailable)

        var unreadable = base
        unreadable[1] = MIDIKeyCommandSurfaceResolver.Cell(
            id: 2,
            role: .textField,
            text: Self.entry.commandName,
            frame: nil
        )
        #expect(resolve(unreadable) == .geometryUnreadable)
    }

    @Test func refusesTallSpanningCellEvenWhenItOverlapsTheCommand() {
        let cells = [
            cell(1, .staticText, "Control Surface", x: 500, y: 100),
            cell(2, .textField, Self.entry.commandName, x: 20, y: 220, width: 360),
            cell(3, .staticText, "CC 98 (127)", x: 500, y: 180, height: 100),
        ]

        #expect(resolve(cells) == .assignmentUnavailable)
    }

    @Test func localeLabelsAreExplicitInputsWithNoEnglishFallback() {
        let localized = MIDIKeyCommandSurfaceResolver.Labels(
            commandNames: ["localized-command-fixture"],
            controlSurfaceColumnTitles: ["localized-column-fixture"]
        )
        let cells = [
            cell(1, .staticText, "localized-column-fixture", x: 500, y: 100),
            cell(2, .textField, "localized-command-fixture", x: 20, y: 220, width: 360),
            cell(3, .staticText, "CC 98 (127)", x: 500, y: 220),
        ]

        #expect(resolve(cells, labels: localized).isResolved)
        #expect(resolve(cells) == .commandUnavailable)
        #expect(resolve(cells, labels: .init(commandNames: [], controlSurfaceColumnTitles: []))
            == .commandUnavailable)
    }
}
