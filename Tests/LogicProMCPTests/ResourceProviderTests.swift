import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("ResourceProvider")
struct ResourceProviderTests {

    // MARK: - Static registration

    @Test("all resource URIs are unique")
    func uniqueURIs() {
        let uris = ResourceProvider.resources.map(\.uri)
        #expect(uris.count == Set(uris).count, "Duplicate resource URI: \(uris)")
    }

    @Test("all template URIs are unique")
    func uniqueTemplateURIs() {
        let uris = ResourceProvider.templates.map(\.uriTemplate)
        #expect(uris.count == Set(uris).count, "Duplicate template URI: \(uris)")
    }

    @Test("new resources are registered: markers, mcu/state, library/inventory, catalogs, workflow skills")
    func newResourcesRegistered() {
        let uris = Set(ResourceProvider.resources.map(\.uri))
        #expect(uris.contains("logic://markers"))
        #expect(uris.contains("logic://mcu/state"))
        #expect(uris.contains("logic://library/inventory"))
        #expect(uris.contains("logic://stock-plugins"))
        #expect(uris.contains("logic://stock-plugins/census"))
        #expect(uris.contains("logic://stock-plugins/capabilities"))
        #expect(uris.contains("logic://stock-instruments"))
        #expect(uris.contains("logic://session-players"))
        #expect(uris.contains("logic://workflow-skills"))
        #expect(uris.contains("logic://workflow-skills/schema"))
        #expect(uris.contains("logic://project/audit"))
        #expect(uris.contains("logic://project/cleanup-plan"))
    }

    @Test("new templates are registered: regions per track, mixer per strip, catalog/search detail")
    func newTemplatesRegistered() {
        let uris = Set(ResourceProvider.templates.map(\.uriTemplate))
        #expect(uris.contains("logic://tracks/{index}/regions"))
        #expect(uris.contains("logic://mixer/{strip}"))
        #expect(uris.contains("logic://stock-plugins/{id}"))
        #expect(uris.contains("logic://stock-plugins/search?query={query}"))
        #expect(uris.contains("logic://stock-instruments/{id}"))
        #expect(uris.contains("logic://stock-instruments/search?query={query}"))
        #expect(uris.contains("logic://session-players/{id}"))
        #expect(uris.contains("logic://workflow-plans/session?prompt={prompt}"))

        #expect(uris.contains("logic://workflow-skills/{id}"))
        #expect(uris.contains("logic://workflow-skills/search?query={query}"))
    }

    @Test("every static resource URI maps to a handler")
    func allURIsHandled() async throws {
        let cache = StateCache()
        let router = ChannelRouter()

        for resource in ResourceProvider.resources {
            let result: ReadResource.Result
            do {
                result = try await ResourceHandlers.read(uri: resource.uri, cache: cache, router: router)
            } catch {
                Issue.record("URI \(resource.uri) threw: \(error)")
                continue
            }
            #expect(!result.contents.isEmpty, "URI \(resource.uri) returned no content")
        }
    }

    @Test("every template URI maps to a handler (happy path)")
    func allTemplatesHandled() async throws {
        let cache = StateCache()
        let router = ChannelRouter()

        // Template probes with concrete indices
        let probes = [
            "logic://tracks/0",
            "logic://tracks/0/regions",
            "logic://mixer/0",
            "logic://stock-plugins/logic.stock.effect.gain",
            "logic://stock-plugins/search?query=gain",
            "logic://stock-instruments/logic.stock.instrument.alchemy",
            "logic://stock-instruments/search?query=sampler",
            "logic://session-players/logic.session_player.drummer",
            "logic://workflow-skills/logic.workflow.plugins.stock_chain_plan",
            "logic://workflow-skills/search?query=plugin",
            "logic://workflow-plans/session?prompt=16-bar%20funk%20in%20E%20minor%20at%20110%20BPM",

        ]
        for uri in probes {
            do {
                _ = try await ResourceHandlers.read(uri: uri, cache: cache, router: router)
            } catch let MCPError.invalidParams(msg) where msg?.contains("No track") == true ||
                                                          msg?.contains("No channel strip") == true {
                // Empty-cache probe: handler recognised the URI but has no data. Pass.
            } catch {
                Issue.record("Template URI \(uri) threw unexpectedly: \(error)")
            }
        }
    }

    // MARK: - Annotations

    @Test("every resource declares a priority annotation in [0, 1]")
    func priorityAnnotations() {
        for r in ResourceProvider.resources {
            let priority = r.annotations?.priority
            #expect(priority != nil, "\(r.uri) missing priority annotation")
            if let p = priority {
                #expect(p >= 0 && p <= 1, "\(r.uri) priority \(p) out of [0, 1]")
            }
        }
    }

    @Test("system/health has the highest priority (1.0)")
    func healthPriority() {
        let health = ResourceProvider.resources.first { $0.uri == "logic://system/health" }
        #expect(health?.annotations?.priority == 1.0)
    }

    @Test("resource annotations use the current public-surface timestamp")
    func resourceAnnotationsUseCurrentSurfaceTimestamp() {
        let timestamps = Set(ResourceProvider.resources.compactMap { $0.annotations?.lastModified })
        #expect(timestamps == ["2026-06-23T00:00:00Z"])
    }

    // MARK: - Stable resource surface (#215)

    @Test("logic://mcu/state is always listed — matches the docs + readable surface")
    func mcuStateAlwaysListed() {
        // #215: `logic://mcu/state` used to be filtered out of the list when
        // the MCU surface was disconnected, even though it stayed directly
        // readable and the docs advertise a stable 18-resource catalog. It is
        // now always present so list == docs == readable surface.
        let uris = ResourceProvider.resources.map(\.uri)
        #expect(uris.contains("logic://mcu/state"))
        #expect(uris.contains("logic://transport/state"))
        #expect(uris.contains("logic://tracks"))
        // The documented stable surface is exactly 18 resources.
        #expect(uris.count == 18)
    }

    // MARK: - Template placeholders

    @Test("template URIs include placeholder tokens in {braces}")
    func templatePlaceholders() {
        for t in ResourceProvider.templates {
            #expect(t.uriTemplate.contains("{"))
            #expect(t.uriTemplate.contains("}"))
        }
    }
}
