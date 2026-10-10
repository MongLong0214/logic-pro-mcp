import Foundation

/// #291 R2 — one channel-strip output assignment, as `logic_mixer set_output_verified` takes it and
/// as it is read back off a strip's output slot.
///
/// No member holds a localized string. A caller names a bus by its number and a physical output by
/// its two ports, so the same request means the same thing in every language Logic runs in.
/// `stereoOutput` and `noOutput` are their own kinds rather than a port pair and an absence:
/// `Stereo Output` is a named output the I/O assignments map (it is not literally `Output 1-2`),
/// and `No Output` is a destination only when it is asked for by name, never an inverse by default.
enum OutputAssignment: Equatable, Sendable {
    case bus(Int)
    case physical(Int, Int)
    case stereoOutput
    case noOutput

    static let busNumbers = 1...256

    /// The string form the dispatcher hands the channel, e.g. `bus:1`, `physical:3-4`.
    var token: String {
        switch self {
        case .bus(let number): "bus:\(number)"
        case .physical(let first, let second): "physical:\(first)-\(second)"
        case .stereoOutput: "stereo_output"
        case .noOutput: "no_output"
        }
    }

    init?(token: String) {
        switch token {
        case "stereo_output":
            self = .stereoOutput
        case "no_output":
            self = .noOutput
        default:
            if token.hasPrefix("bus:"), let number = Self.decimal(String(token.dropFirst(4))) {
                guard let made = Self.make(kind: "bus", number: number, ports: nil).value else { return nil }
                self = made
            } else if token.hasPrefix("physical:") {
                let parts = token.dropFirst(9).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, let first = Self.decimal(String(parts[0])),
                      let second = Self.decimal(String(parts[1])),
                      let made = Self.make(kind: "physical", number: nil, ports: [first, second]).value
                else { return nil }
                self = made
            } else {
                return nil
            }
        }
    }

    /// The public shape: `{kind:"bus", number}`, `{kind:"physical", ports:[a,b]}`, `{kind}`.
    var json: [String: Any] {
        switch self {
        case .bus(let number): ["kind": "bus", "number": number]
        case .physical(let first, let second): ["kind": "physical", "ports": [first, second]]
        case .stereoOutput: ["kind": "stereo_output"]
        case .noOutput: ["kind": "no_output"]
        }
    }

    /// Builds an assignment from the caller's fields, or says what is wrong with them.
    ///
    /// A bus is `1...256` because the popup offers no more. A physical output is exactly two
    /// ascending ports; whether this interface has them is the popup's question, asked later.
    static func make(kind: String, number: Int?, ports: [Int]?) -> (value: OutputAssignment?, problem: String?) {
        switch kind {
        case "bus":
            guard ports == nil else { return (nil, "a bus destination takes 'number', not 'ports'") }
            guard let number, busNumbers.contains(number) else {
                return (nil, "a bus destination needs an integer 'number' in 1...256")
            }
            return (.bus(number), nil)
        case "physical":
            guard number == nil else { return (nil, "a physical destination takes 'ports', not 'number'") }
            guard let ports, ports.count == 2, ports[0] >= 1, ports[0] < ports[1] else {
                return (nil, "a physical destination needs 'ports' as two ascending integers >= 1, e.g. [3, 4]")
            }
            return (.physical(ports[0], ports[1]), nil)
        case "stereo_output", "no_output":
            guard number == nil, ports == nil else {
                return (nil, "a \(kind) destination takes no 'number' or 'ports'")
            }
            return (kind == "no_output" ? .noOutput : .stereoOutput, nil)
        default:
            return (nil, "'kind' must be one of bus, physical, stereo_output, or no_output (no_output only as expected_current)")
        }
    }

    /// What an output slot's description says, or nil when it says nothing this can classify.
    ///
    /// The description is read by R1's `AXLogicProElements.outputSlotDestination`; this only
    /// interprets it. `Stereo Output` and `No Output` are whole-label matches against their
    /// canon-derived sets, and a bus is R1's own `classifyOutputLabel`. A physical pair is parsed for
    /// its port numbers by `pairPorts(ofRuntimeLabel:)`, because a German strip describes one as
    /// `Ausgang 3-4` and R1's physical prefix, derived from the `Output#mix` row, has no `Ausgang`.
    static func observed(slotLabel: String) -> OutputAssignment? {
        let label = slotLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if AXLocalePolicy.noOutputLabel.matches(label, mode: .exact) { return .noOutput }
        if AXLocalePolicy.stereoOutputLabel.matches(label, mode: .exact) { return .stereoOutput }
        let (classification, busNumber) = RoutingGraphPublication.classifyOutputLabel(label)
        if classification == .bus, let busNumber { return .bus(busNumber) }
        if let ports = pairPorts(ofRuntimeLabel: label) { return .physical(ports.0, ports.1) }
        return nil
    }

    /// The bus number an entry of the output popup's Bus submenu names, or nil.
    ///
    /// Apple ships no row composing `Bus 1 → Aux 1`: Logic appends ` → <receiver>` at run time to a
    /// bus that already feeds a strip. The entry is therefore cut at the arrow (U+2192) and the part
    /// before it classified exactly as a slot description is, by R1's `classifyOutputLabel`.
    static func busNumber(ofMenuItemTitle title: String) -> Int? {
        guard let number = classifiedMenuBusNumber(title), busNumbers.contains(number) else { return nil }
        return number
    }

    /// Recognizable routing titles still compete even when their number is out of domain.
    static func isBusMenuItemTitle(_ title: String) -> Bool {
        classifiedMenuBusNumber(title) != nil
    }

    private static func classifiedMenuBusNumber(_ title: String) -> Int? {
        let head = title.split(separator: "\u{2192}", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? title
        let (classification, busNumber) = RoutingGraphPublication.classifyOutputLabel(
            head.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return classification == .bus ? busNumber : nil
    }

    /// The two ports a physical pair label names (`Output 3-4`, `출력 3-4`, `Ausgang 3-4`), or nil.
    ///
    /// Apple ships no `Output %d-%d` row in any locale, so Logic builds these labels at run time and
    /// they are parsed, not matched: a member of `outputPopupOutputSubmenuTitle` (the same word the
    /// popup's Output submenu is titled with), then two decimal port numbers joined by `-`,
    /// ascending. A mono entry (`Output 3`) is not a pair and does not parse.
    static func pairPorts(ofRuntimeLabel label: String) -> (Int, Int)? {
        let candidate = label.trimmingCharacters(in: .whitespacesAndNewlines)
        for member in AXLocalePolicy.outputPopupOutputSubmenuTitle.labels {
            guard let range = candidate.range(of: member, options: [.anchored, .caseInsensitive]) else {
                continue
            }
            let remainder = candidate[range.upperBound...].drop { $0.isWhitespace }
            let parts = remainder.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let first = decimal(String(parts[0])),
                  let second = decimal(String(parts[1])), first >= 1, first < second else {
                continue
            }
            return (first, second)
        }
        return nil
    }

    private static func decimal(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 6, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }
}
