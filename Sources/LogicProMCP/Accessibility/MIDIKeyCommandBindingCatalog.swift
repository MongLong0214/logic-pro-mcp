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
