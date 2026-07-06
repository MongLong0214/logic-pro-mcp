import Foundation

extension SetupDoctor {
    static func productionLatestReleaseLookup() -> UpdateOutcome {
        let repo = "MongLong0214/logic-pro-mcp"
        let url = "https://api.github.com/repos/\(repo)/releases/latest"
        if let result = runProductionCommand(
            executable: "/usr/bin/curl",
            arguments: ["-fsSL", "--max-time", "3", "-H", "Accept: application/vnd.github+json", url],
            timeout: 3.5
        ) {
            switch result {
            case let .completed(output):
                if output.exitCode == 0 {
                    return parseLatestTag(from: output.stdout).map { .found(version: $0) } ?? .parseError
                }
                if output.exitCode == 28 {
                    return .timeout
                }
                if output.exitCode == 22 {
                    return .httpError
                }
            case .timedOut:
                return .timeout
            case .spawnFailed:
                break
            }
        }
        for ghPath in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if let gh = runProductionCommand(
                executable: ghPath,
                arguments: ["release", "view", "--repo", repo, "--json", "tagName", "-q", ".tagName"],
                timeout: 3.5
            )?.output, gh.exitCode == 0 {
                let tag = gh.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return tag.isEmpty ? .parseError : .found(version: tag)
            }
        }
        return .offline
    }


    static func parseLatestTag(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              !tag.isEmpty else {
            return nil
        }
        return tag
    }


}
