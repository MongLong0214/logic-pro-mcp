import Foundation

extension SetupDoctor {
    private enum ClaudeConfigLoadResult {
        case loaded([String: Any])
        case unavailable(String)
    }

    static func readProductionClaudeRegistration(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) -> ClaudeRegistration {
        let object: [String: Any]
        switch loadClaudeConfigObject(at: configURL) {
        case let .loaded(config):
            object = config
        case let .unavailable(reason):
            return .configUnavailable(reason: reason)
        }

        var serverScopes: [[String: Any]] = []
        if let top = object["mcpServers"] as? [String: Any] {
            serverScopes.append(top)
        }
        if let projects = object["projects"] as? [String: Any] {
            for case let project as [String: Any] in projects.values {
                if let scoped = project["mcpServers"] as? [String: Any] {
                    serverScopes.append(scoped)
                }
            }
        }

        for scope in serverScopes {
            for (name, rawEntry) in scope {
                guard let entry = rawEntry as? [String: Any] else { continue }
                let nameMatches = name.localizedCaseInsensitiveContains("logic-pro")
                let command = (entry["command"] as? String) ?? ""
                let commandMatches = command
                    .localizedCaseInsensitiveContains("LogicProMCP")
                if nameMatches && commandMatches {
                    let environment = entry["env"] as? [String: String] ?? [:]
                    return .registered(command: command, environment: environment)
                }
            }
        }
        return .notRegistered
    }


    static func readProductionClaudeDesktopRegistration(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    ) -> ClaudeRegistration {
        let object: [String: Any]
        switch loadClaudeConfigObject(at: configURL) {
        case let .loaded(config):
            object = config
        case let .unavailable(reason):
            return .configUnavailable(reason: reason)
        }
        guard let servers = object["mcpServers"] as? [String: Any] else {
            return .configUnavailable(reason: "config_unreadable")
        }
        for (name, rawEntry) in servers {
            guard let entry = rawEntry as? [String: Any] else { continue }
            let command = (entry["command"] as? String) ?? ""
            if name.localizedCaseInsensitiveContains("logic-pro")
                && command.localizedCaseInsensitiveContains("LogicProMCP") {
                let environment = entry["env"] as? [String: String] ?? [:]
                return .registered(command: command, environment: environment)
            }
        }
        return .notRegistered
    }


    static func readClaudeRegistrationForTesting(configURL: URL) -> ClaudeRegistration {
        readProductionClaudeRegistration(configURL: configURL)
    }

    private static func loadClaudeConfigObject(at configURL: URL) -> ClaudeConfigLoadResult {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .unavailable("config_absent")
        }
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            return .unavailable("config_unreadable")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .unavailable("config_unreadable")
        }
        guard let object = root as? [String: Any] else {
            return .unavailable("config_unreadable")
        }
        return .loaded(object)
    }

}
