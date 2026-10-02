import CryptoKit
import Foundation
import MCP

enum ResourceCacheKey: Hashable, Sendable {
    case document
    case project
    case tracks
    case transport
    case mixer
    case markers
    case regions
    case mcu
}

actor ResourceSubscriptionRegistry {
    private var uris = Set<String>()

    func subscribe(uri: String) throws {
        guard ResourceSubscriptionCatalog.isSubscribable(uri) else {
            throw MCPError.invalidParams("Unknown or unsubscribable resource URI: \(uri)")
        }
        uris.insert(uri)
    }

    func unsubscribe(uri: String) throws {
        guard ResourceSubscriptionCatalog.isSubscribable(uri) else {
            throw MCPError.invalidParams("Unknown or unsubscribable resource URI: \(uri)")
        }
        uris.remove(uri)
    }

    func contains(uri: String) -> Bool {
        uris.contains(uri)
    }

    func subscribedURIs() -> Set<String> {
        uris
    }

    func clear() {
        uris.removeAll()
    }
}

enum ResourceSubscriptionCatalog {
    static let cacheKeyFanout: [ResourceCacheKey: [String]] = [
        .document: [
            "logic://project/info",
            "logic://tracks",
            "logic://mixer",
            "logic://markers",
            "logic://project/audit",
            "logic://project/cleanup-plan",
        ],
        .project: [
            "logic://project/info",
            "logic://project/audit",
            "logic://project/cleanup-plan",
        ],
        .tracks: [
            "logic://tracks",
            "logic://tracks/{index}",
            "logic://project/info",
            "logic://project/audit",
            "logic://project/cleanup-plan",
        ],
        .transport: [
            "logic://transport/state",
            "logic://project/info",
            "logic://project/audit",
            "logic://project/cleanup-plan",
        ],
        .mixer: [
            "logic://mixer",
            "logic://mixer/{strip}",
            "logic://project/audit",
            "logic://project/cleanup-plan",
        ],
        .markers: [
            "logic://markers",
            "logic://project/audit",
        ],
        .regions: [
            "logic://tracks/{index}/regions",
            "logic://project/audit",
        ],
        .mcu: [
            "logic://mcu/state",
            "logic://mixer",
        ],
    ]

    private static let staticURIs = Set(ResourceProvider.resources.map(\.uri))
    private static let templateURIs = Set(ResourceProvider.templates.map(\.uriTemplate))

    static func isSubscribable(_ uri: String) -> Bool {
        guard !uri.contains("{"), !uri.contains("}") else { return false }
        return WorkflowSkillCatalog.resourceRefResolves(
            uri,
            staticURIs: staticURIs,
            templateURIs: templateURIs
        )
    }

    static func affectedSubscribedURIs(cacheKeys: [ResourceCacheKey], subscribedURIs: Set<String>) -> [String] {
        let fanout = Set(cacheKeys.flatMap { cacheKeyFanout[$0] ?? [] })
        let affected = subscribedURIs.filter { uri in
            fanout.contains(uri) || fanout.contains { template in
                WorkflowSkillCatalog.refMatchesTemplate(uri, template: template)
            }
        }
        return affected.sorted()
    }
}

enum ResourceContentHasher {
    private static let volatileKeys: Set<String> = [
        "generated_at",
        "fetched_at",
        "cache_age_sec",
        "mcu_last_feedback_age_ms",
    ]

    static func stableDataHash(fromResourceText text: String) throws -> String {
        let raw = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let stablePayload: Any
        if let object = raw as? [String: Any], let data = object["data"] {
            stablePayload = strippingVolatileKeys(from: data)
        } else {
            stablePayload = strippingVolatileKeys(from: raw)
        }
        let canonical = try JSONSerialization.data(withJSONObject: stablePayload, options: [.sortedKeys])
        let digest = SHA256.hash(data: canonical)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func strippingVolatileKeys(from value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                guard !volatileKeys.contains(pair.key) else { return }
                result[pair.key] = strippingVolatileKeys(from: pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(strippingVolatileKeys)
        }
        return value
    }
}

actor ResourceUpdateNotifier {
    private let registry: ResourceSubscriptionRegistry
    private var lastHashes: [String: String] = [:]

    init(registry: ResourceSubscriptionRegistry) {
        self.registry = registry
    }

    @discardableResult
    func publishChangedResources(
        cacheKeys: [ResourceCacheKey],
        cache: StateCache,
        router: ChannelRouter,
        readResource: @Sendable (String, StateCache, ChannelRouter) async throws -> ReadResource.Result = { uri, cache, router in
            try await ResourceHandlers.read(uri: uri, cache: cache, router: router)
        },
        stopBeforeEachRead: @Sendable () -> Bool = { false },
        notify: @Sendable (String) async throws -> Void
    ) async -> Bool {
        let subscribed = await registry.subscribedURIs()
        guard !subscribed.isEmpty else { return true }

        let uris = ResourceSubscriptionCatalog.affectedSubscribedURIs(
            cacheKeys: cacheKeys,
            subscribedURIs: subscribed
        )
        for uri in uris {
            // #1079 review R3: a resource read is a fresh read of Logic, and the poller's background
            // cycle must not start one once the user is editing text. It reports the stop so the
            // poller can publish these sections later.
            if stopBeforeEachRead() { return false }
            do {
                let result = try await readResource(uri, cache, router)
                let hash = try ResourceContentHasher.stableDataHash(
                    fromResourceText: sharedResourceTextForProduction(result)
                )
                guard lastHashes[uri] != hash else { continue }
                guard await registry.contains(uri: uri) else { continue }
                lastHashes[uri] = hash
                do {
                    try await notify(uri)
                } catch {
                    Log.warn("Resource update notify failed for \(uri): \(error)", subsystem: "server")
                }
            } catch {
                Log.warn("Resource update diff failed for \(uri): \(error)", subsystem: "server")
            }
        }
        return true
    }

    func reset() {
        lastHashes.removeAll()
    }

    private func sharedResourceTextForProduction(_ result: ReadResource.Result) -> String {
        guard let content = result.contents.first else { return "" }
        return content.text ?? ""
    }
}
