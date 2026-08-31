import Foundation

enum ProjectExportArtifactPathPolicy {
    static let supportedArtifactExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "m4a", "mp3",
    ]

    /// The two callers that need to inspect a late-bound stem destination must
    /// distinguish an empty directory from a directory that could not be read.
    /// Treating the latter as empty would allow `fail_if_exists` to fail open.
    enum SupportedAudioEntryEnumeration: Sendable, Equatable {
        case files([String])
        case unreadable(String)
    }

    enum ExistingVariant: Sendable, Equatable {
        case found(String)
        case absent
        case unreadable(String)
    }

    /// Enumerate the entries this export contract calls "audio files": a
    /// top-level, non-directory entry whose suffix is one of
    /// wav/wave/aif/aiff/aifc/m4a/mp3. The suffix is the classification rule;
    /// content is intentionally not parsed here, so a text file named `.wav`
    /// blocks `fail_if_exists` too. Nested entries and other suffixes are out
    /// of scope for both collision detection and post-export observation.
    static func supportedAudioEntries(
        in directory: String,
        fileManager: FileManager
    ) -> SupportedAudioEntryEnumeration {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            return .unreadable("destination_directory_not_found_or_not_directory")
        }
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: root.path)
        } catch {
            return .unreadable("destination_directory_enumeration_failed: \(error.localizedDescription)")
        }
        return .files(entries.compactMap { entry -> String? in
            let candidate = root.appendingPathComponent(entry).standardizedFileURL
            guard supportedArtifactExtensions.contains(candidate.pathExtension.lowercased()) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            return candidate.path
        }
        .sorted())
    }

    static func standardizedStemPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.deletingPathExtension().path
    }

    static func helperProducedPathMatchesPlannedStem(producedPath: String, plannedPath: String) -> Bool {
        standardizedStemPath(producedPath) == standardizedStemPath(plannedPath)
    }

    static func preferredExistingVariant(
        for plannedPath: String,
        fileManager: FileManager
    ) -> ExistingVariant {
        let plannedURL = URL(fileURLWithPath: plannedPath).standardizedFileURL
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: plannedURL.path, isDirectory: &isDir), !isDir.boolValue {
            return .found(plannedURL.path)
        }

        let parent = plannedURL.deletingLastPathComponent()
        let plannedStem = plannedURL.deletingPathExtension().lastPathComponent.lowercased()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
            // Known-path export may create its parent. A missing parent is not
            // an unreadable existing destination and cannot conceal a variant.
            return .absent
        }
        guard parentIsDirectory.boolValue else {
            return .unreadable("artifact_parent_not_directory")
        }
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: parent.path)
        } catch {
            return .unreadable("artifact_parent_enumeration_failed: \(error.localizedDescription)")
        }

        let matches = entries.compactMap { entry -> String? in
            let candidate = parent.appendingPathComponent(entry).standardizedFileURL
            let candidateExtension = candidate.pathExtension.lowercased()
            guard supportedArtifactExtensions.contains(candidateExtension),
                  candidate.deletingPathExtension().lastPathComponent.lowercased() == plannedStem else {
                return nil
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            return candidate.path
        }
            .sorted()

        return matches.first.map(ExistingVariant.found) ?? .absent
    }
}
