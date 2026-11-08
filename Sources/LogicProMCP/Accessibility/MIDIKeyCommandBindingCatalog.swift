import CoreGraphics
import Foundation

/// The exact assignment label Logic displays after a MIDI Key Command binding settles.
///
/// This value describes the visible label only. It does not prove which MIDI source or
/// port produced the assignment.
struct MIDIKeyCommandAssignment: Equatable, Sendable {
    let cc: UInt8
    let value: UInt8

    static func parse(_ raw: String) -> Self? {
        let fields = raw.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "CC",
              isASCIIUnsignedDecimal(fields[1]),
              fields[2].first == "(",
              fields[2].last == ")"
        else {
            return nil
        }

        let valueText = fields[2].dropFirst().dropLast()
        guard isASCIIUnsignedDecimal(valueText),
              let cc = UInt8(fields[1]), cc <= 127,
              let value = UInt8(valueText), value <= 127
        else {
            return nil
        }

        return Self(cc: cc, value: value)
    }

    private static func isASCIIUnsignedDecimal(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

/// Observation of a Key Commands assignment row before source ownership is verified.
enum MIDIKeyCommandBindingObservation: Equatable, Sendable {
    case missing
    case provisional(raw: String)
    case matchingLabelUnverifiedSource(MIDIKeyCommandAssignment)
    case conflicting(MIDIKeyCommandAssignment)
    case unreadable(raw: String?)
}

/// Resolves one filtered Key Commands result without treating a global Y value as
/// row identity. Logic exposes this list as flat cells rather than AX rows, so the
/// assignment must be anchored to the exact Control Surface column and overlap the
/// exact, unique command cell vertically. Any ambiguity fails closed.
enum MIDIKeyCommandSurfaceResolver {
    /// Exact labels selected for the Logic UI locale by the caller. The resolver
    /// deliberately has no English fallback: an unsupported locale must refuse
    /// before it can associate or mutate a row.
    struct Labels: Equatable {
        let commandNames: Set<String>
        let controlSurfaceColumnTitles: Set<String>
    }

    struct Cell: Equatable {
        enum Role: Equatable {
            case searchField
            case textField
            case staticText
            case other
        }

        let id: Int
        let role: Role
        let text: String?
        let frame: CGRect?
    }

    enum Resolution: Equatable {
        case resolved(
            commandCellID: Int,
            assignmentCellID: Int,
            observation: MIDIKeyCommandBindingObservation
        )
        case commandUnavailable
        case ambiguousCommand
        case columnUnavailable
        case assignmentUnavailable
        case ambiguousAssignment
        case geometryUnreadable

        var isResolved: Bool {
            if case .resolved = self { return true }
            return false
        }
    }

    static func resolve(
        entry: MIDIKeyCommandBindingCatalog.Entry,
        labels: Labels,
        cells: [Cell]
    ) -> Resolution {
        guard !labels.commandNames.isEmpty,
              !labels.controlSurfaceColumnTitles.isEmpty else {
            return .commandUnavailable
        }
        let commands = cells.filter { cell in
            cell.role == .textField
                && normalizedCommand(cell.text).map(labels.commandNames.contains) == true
        }
        guard !commands.isEmpty else { return .commandUnavailable }
        guard commands.count == 1, let command = commands.first else {
            return .ambiguousCommand
        }

        let headers = cells.filter { cell in
            cell.role == .staticText
                && cell.text.map(labels.controlSurfaceColumnTitles.contains) == true
        }
        guard headers.count == 1, let header = headers.first else {
            return .columnUnavailable
        }
        guard let commandFrame = validFrame(command.frame),
              let headerFrame = validFrame(header.frame) else {
            return .geometryUnreadable
        }

        let assignments = cells.filter { cell in
            guard cell.role == .staticText,
                  cell.id != header.id,
                  let frame = validFrame(cell.frame)
            else { return false }
            return headerFrame.minX <= frame.midX
                && frame.midX <= headerFrame.maxX
                && sameRowBand(commandFrame, frame)
        }
        guard !assignments.isEmpty else { return .assignmentUnavailable }
        guard assignments.count == 1, let assignment = assignments.first else {
            return .ambiguousAssignment
        }

        return .resolved(
            commandCellID: command.id,
            assignmentCellID: assignment.id,
            observation: MIDIKeyCommandBindingCatalog.observe(
                rawLabel: assignment.text,
                expected: entry
            )
        )
    }

    private static func normalizedCommand(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.hasSuffix("*") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func validFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else { return nil }
        return frame
    }

    private static func sameRowBand(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.minY == rhs.minY && lhs.maxY == rhs.maxY
    }
}

/// The deliberately small set of bindings that setup automation may reason about.
///
/// A matching label remains source-unverified and therefore cannot make the MIDI Key
/// Commands channel ready. Source/port verification belongs to the later setup slice.
struct MIDIKeyCommandBindingCatalog {
    struct Entry: Equatable, Sendable {
        let operation: String
        let commandName: String
        let cc: UInt8
        let channel: UInt8
        let value: UInt8
    }

    static let entries: [Entry] = [
        Entry(
            operation: "transport.toggle_metronome",
            commandName: "Toggle Metronome Click",
            cc: 98,
            channel: 16,
            value: 127
        ),
    ]

    static func disagreements(with mapping: [String: UInt8]) -> [String] {
        entries.compactMap { entry in
            guard mapping[entry.operation] != entry.cc else { return nil }
            let actual = mapping[entry.operation].map(String.init) ?? "missing"
            return "\(entry.operation): catalog=\(entry.cc), mapping=\(actual)"
        }
    }

    static func observe(rawLabel: String?, expected: Entry) -> MIDIKeyCommandBindingObservation {
        guard let rawLabel else { return .unreadable(raw: nil) }
        guard !rawLabel.isEmpty else { return .missing }

        if isProvisional(rawLabel) {
            return .provisional(raw: rawLabel)
        }

        guard let assignment = MIDIKeyCommandAssignment.parse(rawLabel) else {
            return .unreadable(raw: rawLabel)
        }

        guard assignment.cc == expected.cc, assignment.value == expected.value else {
            return .conflicting(assignment)
        }

        return .matchingLabelUnverifiedSource(assignment)
    }

    private static func isProvisional(_ raw: String) -> Bool {
        raw == "1"
    }
}
