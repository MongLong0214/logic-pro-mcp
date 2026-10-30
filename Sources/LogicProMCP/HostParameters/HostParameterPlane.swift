enum PluginParameterProvider: Int, Codable, Comparable, Sendable {
    case mcuC4PluginEdit = 0
    case controlsViewAX = 1
    case separateAUInstance = 2
    case pixelGUI = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A pure, negative-only interpretation of a future MCU plug-in-edit strip
/// identity observation. Even a unique exact match is only a candidate: the
/// product still has no independent readback for Logic's bank offset (#862).
enum MCUStripIdentityDecision: Equatable, Sendable {
    enum Refusal: Equatable, Sendable {
        case independentIdentityUnavailable
        case windowNotFresh
        case windowShapeInvalid
        case requestedStripOutOfRange
        case identityMissing
        case identityMismatch
        case identityAmbiguous
    }

    case refused(Refusal)
    case candidate(identity: String, strip: Int)

    var isVerified: Bool { false }
    var authorizesWrite: Bool { false }

    static func evaluate(
        independentlyObservedIdentity: String?,
        finalWindow: [String],
        requestedStrip: Int,
        windowIsFresh: Bool
    ) -> Self {
        guard let identity = independentlyObservedIdentity, !identity.isEmpty else {
            return .refused(.independentIdentityUnavailable)
        }
        guard windowIsFresh else { return .refused(.windowNotFresh) }
        guard finalWindow.count == 8 else { return .refused(.windowShapeInvalid) }
        guard finalWindow.indices.contains(requestedStrip) else {
            return .refused(.requestedStripOutOfRange)
        }

        let matchingStrips = finalWindow.indices.filter { finalWindow[$0] == identity }
        guard !matchingStrips.isEmpty else { return .refused(.identityMissing) }
        guard matchingStrips.count == 1 else { return .refused(.identityAmbiguous) }
        guard matchingStrips[0] == requestedStrip else { return .refused(.identityMismatch) }
        return .candidate(identity: identity, strip: requestedStrip)
    }
}

extension PluginParameterProvider {
    var canHostVerifiedWrite: Bool {
        // MCU remains potential-only until Logic's bank and exact strip identity have independent readback (#862).
        self == .controlsViewAX
    }
}

func preferredHostPlane(
    available: Set<PluginParameterProvider>
) -> PluginParameterProvider? {
    available.filter(\.canHostVerifiedWrite).min()
}
