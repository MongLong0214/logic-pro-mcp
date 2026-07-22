import Foundation

// Evidence schema for the Event-List MIDI note readback candidate, behind the
// default-off `FeatureFlags.adr010MidiReadback` flag. This file defines the INPUT
// the pure assessment function (`assessReadback`) consumes. Nothing here observes
// Logic; a later live path populates this evidence from Accessibility.
//
// Invariant: the assessment re-computes every completeness gate from raw
// observations or sealed proofs — no caller-asserted conclusion is trusted. The
// proofs that require live observation ship with NO production-constructible
// "proven" case: their proven variant exists only under the debug-only
// `QUALIFICATION_FAULT_SEAM` compilation condition, so a release build cannot
// satisfy the completeness predicate at all (no complete snapshot is produced in
// a release build).

// MARK: - Raw observed rows

/// Opaque identifier for an Event-List column, as reported by Accessibility.
struct AXColumnID: Hashable, Sendable {
    let id: String
}

/// One raw cell of an Event-List row. A cell is either a single data-entry
/// slider (pitch as a raw MIDI integer, channel, velocity via its value
/// description) or a group of sliders (position / length as bar:beat:div:tick).
/// Only the raw observable is carried; interpretation happens in the chokepoint.
struct RawCell: Hashable, Sendable {
    let sliderValue: Double?
    let valueDescription: String?
    let groupSliderValues: [Double]?

    init(sliderValue: Double? = nil, valueDescription: String? = nil, groupSliderValues: [Double]? = nil) {
        self.sliderValue = sliderValue
        self.valueDescription = valueDescription
        self.groupSliderValues = groupSliderValues
    }
}

/// A raw Event-List row keyed by column. Structural equality is the canonical
/// digest the chokepoint uses for the two-pass stability check.
typealias RawEventRow = [AXColumnID: RawCell]

/// Stable ordinal key of a materialized row. Contiguity is defined by the
/// integer successor relation, so a coverage gap under lazy virtualization is
/// detectable (non-vacuous).
struct RowKey: Hashable, Comparable, Sendable {
    let index: Int
    static func < (lhs: RowKey, rhs: RowKey) -> Bool { lhs.index < rhs.index }
}

// MARK: - Column identity binding

/// Note-field column roles. There is no event-type role: note-only membership
/// of the harvested rows is guaranteed by the filter proof (all note events
/// visible, no scoping filter), not by a per-row type re-check.
enum ColumnRole: Hashable, Sendable {
    case position, channel, pitch, velocity, length
}

/// Column binding by stable identity. Arity-only matching is intentionally not
/// representable here. The proven variant carries the live AX column ids and is
/// debug-seam-only, so a release build cannot bind columns.
enum HeaderIdentityProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case proven([ColumnRole: AXColumnID])
    #endif

    var roles: [ColumnRole: AXColumnID]? {
        #if QUALIFICATION_FAULT_SEAM
        if case let .proven(map) = self { return map }
        #endif
        return nil
    }
}

enum ColumnBinding: Sendable {
    case headerIdentity(HeaderIdentityProof)
    case unresolved
}

/// Three mutually-distinct values drawn from EXISTING notes, used by the
/// chokepoint to re-derive column uniqueness against the harvested rows. Values
/// are raw; the chokepoint checks each resolves to exactly one column.
struct CalibrationTriple: Sendable {
    let pitch: Double
    let velocity: Double
    let startTickValue: Double
}

// MARK: - Region identity

/// The registry's resolution of a `MIDIRegionReference` into the field set the
/// observed identity also exposes. Minted ONLY inside `RegionIdentityRegistry`
/// (see that file); its initializer is fileprivate there so a caller cannot
/// forge a proof binding an arbitrary identity to an arbitrary region.
struct ResolvedRegionIdentity: Equatable, Sendable {
    let name: String
    let ordinal: Int
    let startTick: Int64
}

/// What Logic ACTUALLY reported for the selected region. Proven variant is
/// debug-seam-only → region-match is unsatisfiable in a release build.
enum ObservedRegionIdentityProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case proven(ResolvedRegionIdentity)
    #endif

    var identity: ResolvedRegionIdentity? {
        #if QUALIFICATION_FAULT_SEAM
        if case let .proven(value) = self { return value }
        #endif
        return nil
    }
}

// MARK: - Filter, count, harvest, timing

/// Raw Event-List filter checkbox states. The chokepoint DERIVES whether all
/// note events are visible with no hiding/scoping filter — it does not accept a
/// pre-computed boolean. The live path must supply the COMPLETE set of filter
/// checkboxes: the derivation treats an absent scoping checkbox as "off", so
/// filter-evidence completeness is a live qualification requirement (an
/// incomplete checkbox list could otherwise hide an active scope filter).
struct FilterEvidence: Sendable {
    struct Checkbox: Sendable {
        let id: String
        let checked: Bool
    }
    let checkboxes: [Checkbox]
}

/// What the Event-List "N Events" count actually counts. Proven variant
/// is debug-seam-only, so the count can never be treated
/// as an all-events-in-region oracle in a release build.
enum CountSemanticsProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case provenAllEventsInRegion
    #endif

    var isAllEventsInRegion: Bool {
        #if QUALIFICATION_FAULT_SEAM
        if case .provenAllEventsInRegion = self { return true }
        #endif
        return false
    }
}

struct ItemCountEvidence: Sendable {
    let rawCountText: String
    let semanticsProof: CountSemanticsProof
}

/// Proof that the whole Event-List table was scrolled/materialized. Live-only →
/// debug-seam-only proven variant.
enum HarvestExhaustionProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case proven
    #endif

    var isProven: Bool {
        #if QUALIFICATION_FAULT_SEAM
        if case .proven = self { return true }
        #endif
        return false
    }
}

/// Two independent read passes of the keyed raw rows. The chokepoint computes
/// and compares the canonical digest (structural equality) itself — no
/// caller-supplied stability flag.
struct RowHarvest: Sendable {
    let orderedRowKeys: [RowKey]
    let passA: [RowKey: RawEventRow]
    let passB: [RowKey: RawEventRow]
    let exhaustion: HarvestExhaustionProof
}

/// BBT→tick conversion inputs. Region-relative frame; PPQ is
/// tempo-independent. The proven variant is added only after the conversion is
/// validated against independent ground truth → debug-seam-only for now.
enum TimingEvidence: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case proven
    #endif

    var isProven: Bool {
        #if QUALIFICATION_FAULT_SEAM
        if case .proven = self { return true }
        #endif
        return false
    }
}

// MARK: - Evidence package

struct EventListReadbackEvidence: Sendable {
    let requestedRegion: MIDIRegionReference
    let resolvedIdentity: RegistryResolvedIdentityProof
    let observedRegion: ObservedRegionIdentityProof
    let projectEpochBefore: UInt64
    let projectEpochAfter: UInt64
    let ppq: Int
    let columnBinding: ColumnBinding
    let filter: FilterEvidence
    let itemCount: ItemCountEvidence
    let harvest: RowHarvest
    let timing: TimingEvidence
    let calibration: CalibrationTriple?
}
