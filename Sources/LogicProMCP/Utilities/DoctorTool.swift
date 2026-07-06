enum DoctorTool: String, CaseIterable, Sendable {
    case codesign
    case xattr
    case lipo
    case strings
    case sqlite3
    case plutil
    case which
    case brew
    case osascript
    case curl
    case gh

    static func resolve(_ executable: String) -> DoctorTool? {
        switch executable {
        case "/usr/bin/codesign": return .codesign
        case "/usr/bin/xattr": return .xattr
        case "/usr/bin/lipo": return .lipo
        case "/usr/bin/strings": return .strings
        case "/usr/bin/sqlite3": return .sqlite3
        case "/usr/bin/plutil": return .plutil
        case "/usr/bin/which": return .which
        case "/usr/bin/osascript": return .osascript
        case "/usr/bin/curl": return .curl
        case "/opt/homebrew/bin/brew", "/usr/local/bin/brew": return .brew
        case "/opt/homebrew/bin/gh", "/usr/local/bin/gh": return .gh
        default: return nil
        }
    }
}
