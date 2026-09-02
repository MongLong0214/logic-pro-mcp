import Foundation

/// The seven *observed* leaves of Logic's Track > Sort Tracks By menu.
///
/// These are stable API identities, not translated UI text. `label` remains in
/// `AXLocalePolicy`, and `measuredLabel(for:)` deliberately returns nil outside
/// a locale with an explicit menu measurement.
enum TrackSortCriterion: String, CaseIterable, Sendable, Hashable {
    case midiChannel = "midi_channel"
    case audioChannel = "audio_channel"
    case outputChannel = "output_channel"
    case instrumentName = "instrument_name"
    case trackName = "track_name"
    case used
    case creationDate = "creation_date"

    var label: AXLocalePolicy.LabelSet {
        switch self {
        case .midiChannel: AXLocalePolicy.sortTracksByMIDIChannelMenuItem
        case .audioChannel: AXLocalePolicy.sortTracksByAudioChannelMenuItem
        case .outputChannel: AXLocalePolicy.sortTracksByOutputChannelMenuItem
        case .instrumentName: AXLocalePolicy.sortTracksByInstrumentNameMenuItem
        case .trackName: AXLocalePolicy.sortTracksByTrackNameMenuItem
        case .used: AXLocalePolicy.sortTracksByUsedMenuItem
        case .creationDate: AXLocalePolicy.sortTracksByCreationDateMenuItem
        }
    }

    /// The #448 menu measurement is Korean-only. Logic's partially localized
    /// menu bar is not a translation oracle: an English or unknown UI locale is
    /// a missing measurement, even if a human could guess a plausible label.
    func measuredLabel(for localeIdentifier: String?) -> String? {
        // `logicUILocaleIdentifier` publishes BCP-47 (`ko-KR`), while the
        // original #448 fixture used the underscore spelling (`ko_KR`). Both
        // identify the one measured Korean UI; accepting this formatting
        // difference does not infer a label for another locale.
        guard localeIdentifier == "ko_KR" || localeIdentifier == "ko-KR" else { return nil }
        return label.canonical
    }
}

/// An issued track reference together with the pre-sort rail location it named.
///
/// `expected_order` is a caller-facing list of the `trk_…` values emitted by
/// `logic://tracks`; this value is only the dispatcher-to-channel witness that
/// lets the channel bind those references to one strict pre-sort AX read. We
/// deliberately do not use arrangement indexes as the public identity: sorting
/// changes them. We also do not manufacture `(name, ordinal)` identities: no
/// measurement establishes that Logic preserves an equal-name ordinal through a
/// sort. If a reference no longer resolves, or its bound pre-sort row is gone,
/// the operation refuses before pressing the menu and names that reference.
struct TrackSortExpectedTrack: Codable, Equatable, Sendable {
    let reference: String
    let beforeIndex: Int
    let beforeName: String

    enum CodingKeys: String, CodingKey {
        case reference = "track_ref"
        case beforeIndex = "before_index"
        case beforeName = "before_name"
    }
}

/// Pure decision core for the track-sort transaction. The AX layer supplies
/// the two independently read arrangement orders and the menu actuation result;
/// keeping those seams here makes every no-live-project safety branch testable.
enum TrackSortVerifier {
    enum OrderRead: Equatable, Sendable {
        case read([String])
        case unavailable
    }

    enum Actuation: Equatable, Sendable {
        case actuated
        case unmeasuredLocale(String)
        case criterionLabelMissing(String)
        case disabledMenuItem(String)
        case pressFailed(String)
    }

    enum Refusal: Equatable, Sendable {
        case beforeOrderUnreadable
        case expectedOrderIsNotBeforeOrder
        case unmeasuredLocale(String)
        case criterionLabelMissing(String)
        case disabledMenuItem(String)
        case menuPressFailed(String)
    }

    enum Uncertainty: Equatable, Sendable {
        case afterOrderUnreadable
        case afterOrderMismatch
        case alreadySortedCommandUnobservable
    }

    enum Outcome: Equatable, Sendable {
        case verified
        case refused(Refusal)
        case uncertain(Uncertainty)
    }

    /// A changed order is not a verifier: another criterion could produce it.
    /// The caller supplies the complete expected *track-reference* order
    /// derived from the requested criterion, and it must be a permutation of
    /// the pre-write order. State A therefore requires an exact post-write
    /// match.
    ///
    /// A correct sort of an already-sorted project is observationally identical
    /// to a menu press that did nothing. We do not inspect Undo text or infer an
    /// action from AX's return code, so that case intentionally remains State B.
    static func execute(
        criterion: TrackSortCriterion,
        expectedOrder: [String],
        before: () -> OrderRead,
        actuate: () -> Actuation,
        after: () -> OrderRead
    ) -> Outcome {
        _ = criterion // Keeps the API explicit at this transaction boundary.

        guard case .read(let beforeOrder) = before() else {
            return .refused(.beforeOrderUnreadable)
        }
        guard ordersContainSameUniqueTrackReferences(beforeOrder, expectedOrder) else {
            return .refused(.expectedOrderIsNotBeforeOrder)
        }

        switch actuate() {
        case .actuated:
            break
        case .unmeasuredLocale(let locale):
            return .refused(.unmeasuredLocale(locale))
        case .criterionLabelMissing(let label):
            return .refused(.criterionLabelMissing(label))
        case .disabledMenuItem(let label):
            return .refused(.disabledMenuItem(label))
        case .pressFailed(let label):
            return .refused(.menuPressFailed(label))
        }

        guard case .read(let afterOrder) = after() else {
            return .uncertain(.afterOrderUnreadable)
        }
        guard afterOrder == expectedOrder else {
            return .uncertain(.afterOrderMismatch)
        }
        guard beforeOrder != expectedOrder else {
            return .uncertain(.alreadySortedCommandUnobservable)
        }
        return .verified
    }

    private static func ordersContainSameUniqueTrackReferences(_ before: [String], _ expected: [String]) -> Bool {
        guard before.count == expected.count,
              Set(before).count == before.count,
              Set(expected).count == expected.count else {
            return false
        }
        return Set(before) == Set(expected)
    }
}
