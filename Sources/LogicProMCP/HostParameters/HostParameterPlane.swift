enum PluginParameterProvider: Int, Codable, Comparable, Sendable {
    case mcuC4PluginEdit = 0
    case controlsViewAX = 1
    case separateAUInstance = 2
    case pixelGUI = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
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
