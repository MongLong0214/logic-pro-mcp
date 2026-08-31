import Foundation

/// The planner receives a captured live track scan from the dispatcher. It is
/// deliberately separate from the on-disk project metadata: metadata can tell
/// us a track count, but not the identity-backed names the stem plan promises.
enum ProjectExportStemSubjectInventory: Sendable, Equatable {
    enum Resolution: Sendable, Equatable {
        case scanned([ProjectExportStemSubject])
        case unavailable(String)
    }

    case scanned(projectPath: String, subjects: [ProjectExportStemSubject])
    case unavailable(reason: String)

    func subjects(for projectPath: String) -> Resolution {
        switch self {
        case .scanned(let scannedPath, let subjects):
            let expected = URL(fileURLWithPath: projectPath).standardizedFileURL.path
            let observed = URL(fileURLWithPath: scannedPath).standardizedFileURL.path
            guard expected == observed else {
                return .unavailable(
                    "the live track scan belongs to \(observed), not planned project \(expected)"
                )
            }
            return .scanned(subjects)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}
