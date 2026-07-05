import Foundation
import MCP

/// Library-inventory resource: disk-cache read with path allowlist + size cap.
extension ResourceHandlers {
    /// Max bytes we will read from the library-inventory cache file. A real
    /// scan is typically <1 MiB; this cap exists so a maliciously-large file
    /// (e.g. via a hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` symlink target)
    /// can't OOM the server.
    static let libraryInventoryMaxBytes: Int = 64 * 1024 * 1024  // 64 MiB

    /// Resolve the library-inventory cache file. Checks (in order):
    /// 1. `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override (absolute path; symlinks resolved + validated)
    /// 2. `<CWD>/Resources/library-inventory.json` — dev/CLI launches from repo root
    /// 3. `~/Library/Application Support/LogicProMCP/library-inventory.json` — daemon/launchd launches where CWD=/
    private static func libraryInventoryCandidatePaths() -> [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_LIBRARY_INVENTORY"],
           !override.isEmpty {
            paths.append(override)
        }
        paths.append("Resources/library-inventory.json")
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            paths.append(
                appSupport.appendingPathComponent("LogicProMCP/library-inventory.json").path
            )
        }
        return paths
    }

    /// Default directory prefixes the library-inventory cache file is allowed
    /// to live under. Computed at call time (not a static let) because tests
    /// rely on `HOME` being mutable and because `<CWD>/Resources/` is itself
    /// a moving target across the test runner / dev shell / launchd contexts.
    ///
    /// All prefixes are normalised via `URL(...).resolvingSymlinksInPath()`
    /// and are guaranteed to end in `/` so a path comparison of the form
    /// `resolved.hasPrefix(prefix)` cannot be tricked by a sibling like
    /// `/Users/example/Music/Logic-evil/x.json` matching `/Users/example/Music/Logic`.
    static func defaultLibraryInventoryAllowedPrefixes() -> [String] {
        var prefixes: [String] = []

        // (1) ~/Library/Application Support/LogicProMCP/  — production location
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            prefixes.append(
                appSupport.appendingPathComponent("LogicProMCP", isDirectory: true).path
            )
        }

        // (2) <CWD>/Resources/  — repo-root dev/CLI launches
        let cwd = FileManager.default.currentDirectoryPath
        prefixes.append(URL(fileURLWithPath: cwd).appendingPathComponent("Resources", isDirectory: true).path)

        // (3) ~/Music/Logic/  — Logic Pro's own user library directory; users
        //     reasonably stash a hand-built inventory beside their patches.
        let home = NSHomeDirectory()
        prefixes.append(URL(fileURLWithPath: home).appendingPathComponent("Music/Logic", isDirectory: true).path)

        // (4) Operator-extended allowlist via env. ADDITIVE (not replacement)
        //     so the safe defaults can never be removed by a misconfigured
        //     daemon. Colon-separated, matching `PATH` conventions.
        if let extra = ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_INVENTORY_ALLOWLIST"],
           !extra.isEmpty {
            for raw in extra.split(separator: ":") {
                let s = String(raw)
                guard !s.isEmpty else { continue }
                prefixes.append(s)
            }
        }

        // Normalise: resolve symlinks (so a prefix can't escape via its own
        // symlink), expand `~`, and force a trailing `/` for safe prefix
        // comparison. Empties / duplicates filtered out.
        var seen = Set<String>()
        var out: [String] = []
        for p in prefixes {
            let expanded = (p as NSString).expandingTildeInPath
            var resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            if !resolved.hasSuffix("/") { resolved += "/" }
            if seen.insert(resolved).inserted {
                out.append(resolved)
            }
        }
        return out
    }

    /// Validate that the candidate path is safe to read as the library cache.
    /// Returns the resolved absolute path on success, or nil on rejection.
    /// Mitigations against a hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` symlink
    /// target (e.g. an attacker with daemon env-var access pointing us at a
    /// sensitive file):
    /// - Must end in `.json` after symlink resolution (so `/etc/passwd` and
    ///   binary secrets won't be served raw)
    /// - Must be a regular file (not a directory)
    /// - Must be smaller than `libraryInventoryMaxBytes`
    /// - Resolved path must sit under one of `allowedPrefixes` (post-symlink),
    ///   so an env-var pointing at `/etc/passwd.json` or a symlink chain
    ///   escaping a sandboxed dir is rejected before any bytes are read.
    /// Always logs the resolved path on reject so operators can audit.
    /// Internal (not private) so the test target can exercise it directly
    /// with synthesised allowlists; production callers always use the default
    /// allowlist computed by `defaultLibraryInventoryAllowedPrefixes()`.
    static func validateLibraryInventoryPath(
        _ rawPath: String,
        allowedPrefixes: [String]? = nil
    ) -> String? {
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        guard resolved.hasSuffix(".json") else {
            Log.warn(
                "library-inventory path rejected (must end in .json): raw=\(rawPath), resolved=\(resolved)",
                subsystem: Log.Subsystem.library
            )
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
           let size = attrs[.size] as? Int, size > libraryInventoryMaxBytes {
            Log.warn(
                "library-inventory file exceeds \(libraryInventoryMaxBytes) bytes — refusing to load (raw=\(rawPath), resolved=\(resolved), size=\(size))",
                subsystem: Log.Subsystem.library
            )
            return nil
        }
        // Path-prefix allowlist. The previous validation only enforced the
        // `.json` suffix, which left any user-readable JSON file (Keychain
        // export, app config, third-party token caches) reachable through a
        // hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env var. We now require
        // the post-symlink-resolution path to live inside an allowlisted
        // directory tree, defaulting to the inventory's natural homes
        // (~/Library/Application Support/LogicProMCP/, <CWD>/Resources/,
        // ~/Music/Logic/) plus an optional additive `LOGIC_PRO_MCP_INVENTORY_ALLOWLIST`.
        let prefixes = allowedPrefixes ?? defaultLibraryInventoryAllowedPrefixes()
        // Prefixes are normalized with a trailing "/", so comparing the full
        // resolved file path accepts files under the prefix while rejecting
        // sibling-prefix paths such as `/foo-evil/x.json` for prefix `/foo/`.
        let inAllowlist = prefixes.contains { resolved.hasPrefix($0) }
        guard inAllowlist else {
            Log.warn(
                "library-inventory path rejected (outside allowlist): raw=\(rawPath), resolved=\(resolved), allowlist=\(prefixes.joined(separator: ", "))",
                subsystem: Log.Subsystem.library
            )
            return nil
        }
        return resolved
    }

    static func readLibraryInventory(uri: String) async throws -> ReadResource.Result {
        let candidates = libraryInventoryCandidatePaths()
        let allowlist = defaultLibraryInventoryAllowedPrefixes()
        for path in candidates {
            guard let resolved = validateLibraryInventoryPath(path, allowedPrefixes: allowlist) else { continue }
            guard let data = FileManager.default.contents(atPath: resolved) else { continue }
            // Parse before serving: we advertise this resource as
            // `application/json`, so corrupt or attacker-shaped bytes must
            // not reach the MCP client under that mimetype. On parse
            // failure we fall through to the next candidate and log.
            guard (try? JSONSerialization.jsonObject(with: data, options: [])) != nil,
                  let s = String(data: data, encoding: .utf8) else {
                Log.warn(
                    "library-inventory file is not valid JSON, skipping: \(resolved)",
                    subsystem: Log.Subsystem.library
                )
                continue
            }
            // v3.1.0 (T7) — wrap with cache envelope based on file mtime.
            // Clients can now detect stale inventories (e.g. before the first
            // `scan_library` of a new Logic install) without parsing the
            // inventory payload itself.
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
            let mtime = attrs?[.modificationDate] as? Date
            let json = wrapWithCacheEnvelope(bodyJSON: s, fetchedAt: mtime)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        // No cache found at any candidate — warn loudly so daemon deployments
        // where CWD=/ don't silently return an empty placeholder forever.
        Log.warn(
            "library-inventory cache missing at candidate paths: \(candidates.joined(separator: ", ")). Run logic_library scan, or set LOGIC_PRO_MCP_LIBRARY_INVENTORY to an absolute path under the allowlist (extend via LOGIC_PRO_MCP_INVENTORY_ALLOWLIST if needed).",
            subsystem: Log.Subsystem.library
        )
        let json = #"{"cached":false,"note":"Run logic_library scan to populate (or set LOGIC_PRO_MCP_LIBRARY_INVENTORY env var)"}"#
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

}
