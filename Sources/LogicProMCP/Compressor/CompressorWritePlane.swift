enum CompressorWritePlane: Int, Comparable, Hashable, Sendable {
    case controlsViewAX = 0
    case mcuC4 = 1
    case qualifiedNativeAdapter = 2
    case coordinateOnly = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

func canPublicVerifiedWrite(_ plane: CompressorWritePlane) -> Bool {
    plane != .coordinateOnly
}

func preferredPlane(
    available: Set<CompressorWritePlane>
) -> CompressorWritePlane? {
    available.min()
}
