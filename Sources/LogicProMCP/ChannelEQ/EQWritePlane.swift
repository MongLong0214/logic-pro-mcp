enum EQWritePlane: Int, Comparable, Sendable {
    case c4ControlSurface = 0
    case qualifiedAXControls = 1
    case coordinateOnly = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension EQWritePlane {
    // Instance member (not a free `canPublicVerifiedWrite(_:)` overload) so it
    // does not collide with the identically-named ADR-011 compressor helper —
    // a bare `.coordinateOnly` at a call site would otherwise be ambiguous.
    var isPublicVerifiedWritable: Bool {
        self != .coordinateOnly
    }
}
