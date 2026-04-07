import Foundation

enum ManualValidationChannel: String, Sendable, CaseIterable, Codable {
    case midiKeyCommands = "MIDIKeyCommands"
    case scripter = "Scripter"

    static func parse(_ value: String) -> ManualValidationChannel? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "midikeycommands", "keycommands", "keycmd":
            return .midiKeyCommands
        case "scripter":
            return .scripter
        default:
            return nil
        }
    }
}

struct ManualValidationApproval: Sendable, Codable, Equatable {
    let approvedAt: Date
    let note: String?

    enum CodingKeys: String, CodingKey {
        case approvedAt = "approved_at"
        case note
    }
}

protocol ManualValidationStoring: Actor {
    func isApproved(_ channel: ManualValidationChannel) async -> Bool
    func approval(for channel: ManualValidationChannel) async -> ManualValidationApproval?
    func approve(_ channel: ManualValidationChannel, note: String?) async throws
    func revoke(_ channel: ManualValidationChannel) async throws
    func list() async -> [ManualValidationChannel: ManualValidationApproval]
}

private struct ManualValidationFile: Codable {
    var approvals: [String: ManualValidationApproval] = [:]
}

actor ManualValidationStore: ManualValidationStoring {
    private let fileURL: URL

    init(fileURL: URL = ManualValidationStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LogicProMCP/operator-approvals.json")
    }

    static func summary(for approvals: [ManualValidationChannel: ManualValidationApproval]) -> String {
        guard !approvals.isEmpty else {
            return "No manual-validation channels have been approved."
        }

        let formatter = ISO8601DateFormatter()
        let lines = approvals
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { channel, approval -> String in
                let noteSuffix: String
                if let note = approval.note, !note.isEmpty {
                    noteSuffix = " — \(note)"
                } else {
                    noteSuffix = ""
                }
                return "\(channel.rawValue): approved at \(formatter.string(from: approval.approvedAt))\(noteSuffix)"
            }
        return lines.joined(separator: "\n")
    }

    func isApproved(_ channel: ManualValidationChannel) async -> Bool {
        await approval(for: channel) != nil
    }

    func approval(for channel: ManualValidationChannel) async -> ManualValidationApproval? {
        let file = loadFile()
        return file.approvals[channel.rawValue]
    }

    func approve(_ channel: ManualValidationChannel, note: String?) async throws {
        var file = loadFile()
        file.approvals[channel.rawValue] = ManualValidationApproval(
            approvedAt: Date(),
            note: normalized(note)
        )
        try save(file)
    }

    func revoke(_ channel: ManualValidationChannel) async throws {
        var file = loadFile()
        file.approvals.removeValue(forKey: channel.rawValue)
        try save(file)
    }

    func list() async -> [ManualValidationChannel: ManualValidationApproval] {
        let file = loadFile()
        var result: [ManualValidationChannel: ManualValidationApproval] = [:]
        for channel in ManualValidationChannel.allCases {
            if let approval = file.approvals[channel.rawValue] {
                result[channel] = approval
            }
        }
        return result
    }

    private func loadFile() -> ManualValidationFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(ManualValidationFile.self, from: data)
        } catch {
            Log.warn("Failed to read manual validation store: \(error)", subsystem: "validation")
            return .init()
        }
    }

    private func save(_ file: ManualValidationFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    private func normalized(_ note: String?) -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
