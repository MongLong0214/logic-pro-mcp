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

    @Test("new resources are registered: markers, mcu/state, library/inventory")
    func newResourcesRegistered() {
        let uris = Set(ResourceProvider.resources.map(\.uri))
        #expect(uris.contains("logic://markers"))
        #expect(uris.contains("logic://mcu/state"))
        #expect(uris.contains("logic://library/inventory"))
    }

    @Test("new templates are registered: regions per track, mixer per strip")
    func newTemplatesRegistered() {
        let uris = Set(ResourceProvider.templates.map(\.uriTemplate))
        #expect(uris.contains("logic://tracks/{index}/regions"))
        #expect(uris.contains("logic://mixer/{strip}"))
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

    // MARK: - Dynamic MCU filtering

    @Test("MCU-specific resources are hidden when MCU is disconnected")
    func mcuFiltering() {
        let connected = ResourceProvider.resources(mcuConnected: true).map(\.uri)
        let disconnected = ResourceProvider.resources(mcuConnected: false).map(\.uri)

        #expect(connected.contains("logic://mcu/state"))
        #expect(!disconnected.contains("logic://mcu/state"))
        // Non-MCU resources always visible.
        #expect(disconnected.contains("logic://transport/state"))
        #expect(disconnected.contains("logic://tracks"))
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
