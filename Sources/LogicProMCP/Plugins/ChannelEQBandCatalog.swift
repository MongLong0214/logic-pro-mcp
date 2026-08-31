/// The named Channel EQ band controls measured for #301.
///
/// Every range below is in raw `AXValue` units. It would be dishonest to call
/// the frequency range Hz: the supplied Logic 12.x (ko) observations show a
/// non-linear raw-to-Hz relationship. Engineering-unit requests are therefore
/// matched against Logic's own `AXValueDescription`; this catalog never maps an
/// engineering value back to a raw slider value.
enum ChannelEQBandCatalog {
    struct Parameter: Equatable, Sendable {
        let id: String
        let bandName: String
        let parameterName: String
        let displayName: String
        let axDescription: String
        /// The only range that was measured: raw `AXValue` units.
        let rawUnit: String
        /// An engineering rendering Logic exposes in `AXValueDescription`, if
        /// this control has one. A nil value means raw-only (the cut-band Order).
        let displayUnit: String?
        let range: ClosedRange<Double>

        var declaredUnits: [String] {
            [rawUnit] + (displayUnit.map { [$0] } ?? [])
        }
    }

    static let rawUnit = "raw_ax_value"
    /// A cap on accepted AX nudges. The widest measured raw range is 0...1050;
    /// the small margin lets the walk report its actual outcome rather than
    /// relying on an assumed one-step-per-raw-unit relationship.
    static let incrementWalkBudget = 1_100

    /// Data only; `StockPluginCatalog` registers these named entries and their
    /// measured raw behavior. The recorded values justify constants here, not
    /// any claim that this source has verified a live write round trip.
    static let parameters: [Parameter] = bands.flatMap { band in
        [ParameterKind.frequency, band.levelParameter, .q].map { kind in
            let name = "\(band.displayName) \(kind.displayName)"
            return Parameter(
                id: "\(band.id)_\(kind.id)",
                bandName: band.displayName,
                parameterName: kind.displayName,
                displayName: name,
                axDescription: name,
                rawUnit: rawUnit,
                displayUnit: kind.displayUnit,
                range: kind.range(for: band.qRange)
            )
        }
    }

    /// Resolve public names only. There are deliberately no band ordinals or
    /// slider positions in this path: the resolved AX description is the named
    /// catalog entry's own description.
    static func parameter(bandName: String, parameterName: String) -> Parameter? {
        let normalizedBand = normalizedName(bandName)
        let normalizedParameter = normalizedName(parameterName)
        return parameters.first {
            normalizedName($0.bandName) == normalizedBand
                && normalizedName($0.parameterName) == normalizedParameter
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct Band: Sendable {
        let id: String
        let displayName: String
        let levelParameter: ParameterKind
        let qRange: ClosedRange<Double>
    }

    private enum ParameterKind: Sendable {
        case frequency
        case gain
        case q
        case order

        var id: String {
            switch self {
            case .frequency: "frequency"
            case .gain: "gain"
            case .q: "q"
            case .order: "order"
            }
        }

        var displayName: String {
            switch self {
            case .frequency: "Frequency"
            case .gain: "Gain"
            case .q: "Q"
            case .order: "Order"
            }
        }

        var displayUnit: String? {
            switch self {
            case .frequency: "Hz"
            case .gain: "dB"
            case .q: "Q"
            case .order: nil
            }
        }

        func range(for qRange: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .frequency: Self.frequencyRawRange
            case .gain: Self.gainRawRange
            case .q: qRange
            case .order: Self.orderRawRange
            }
        }

        // Supplied #301 measurements: Frequency AXValue 0...1050, Gain
        // 0...480, and Order 0...5. These are raw slider bounds, not a
        // conversion to the values Logic renders in `AXValueDescription`.
        private static let frequencyRawRange: ClosedRange<Double> = 0 ... 1_050
        private static let gainRawRange: ClosedRange<Double> = 0 ... 480
        private static let orderRawRange: ClosedRange<Double> = 0 ... 5
    }

    private static let shelfQRawRange: ClosedRange<Double> = 0 ... 52
    private static let peakOrCutQRawRange: ClosedRange<Double> = 0 ... 127

    // Low/High Cut retain Q and substitute Order for Gain. Generating the
    // three parameters per band preserves that distinction without a fragile
    // hand-written list of 24 strings.
    private static let bands: [Band] = [
        Band(
            id: "low_cut",
            displayName: "Low Cut",
            levelParameter: .order,
            qRange: peakOrCutQRawRange
        ),
        Band(
            id: "low_shelf",
            displayName: "Low Shelf",
            levelParameter: .gain,
            qRange: shelfQRawRange
        ),
        Band(
            id: "peak_1",
            displayName: "Peak 1",
            levelParameter: .gain,
            qRange: peakOrCutQRawRange
        ),
        Band(
            id: "peak_2",
            displayName: "Peak 2",
            levelParameter: .gain,
            qRange: peakOrCutQRawRange
        ),
        Band(
            id: "peak_3",
            displayName: "Peak 3",
            levelParameter: .gain,
            qRange: peakOrCutQRawRange
        ),
        Band(
            id: "peak_4",
            displayName: "Peak 4",
            levelParameter: .gain,
            qRange: peakOrCutQRawRange
        ),
        Band(
            id: "high_shelf",
            displayName: "High Shelf",
            levelParameter: .gain,
            qRange: shelfQRawRange
        ),
        Band(
            id: "high_cut",
            displayName: "High Cut",
            levelParameter: .order,
            qRange: peakOrCutQRawRange
        ),
    ]
}
