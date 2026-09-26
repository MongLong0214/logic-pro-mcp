import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #291 R0: `logic://mixer` binds the graph's project reference through the same derivation as
/// `logic://project/info`, from the cached name and bundle path only.
@Suite(.serialized)
struct Issue291ProjectBindingTests {
    @Test("the project reference is the same whichever resource issued it first")
    func projectReferenceIsTheSameWhicheverResourceIssuedItFirst() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            // Padded on purpose: `TargetRegistry.bind` drops every other project binding when a
            // different descriptor is bound, so a reader that skips the shared trimming evicts the
            // other reader's reference on alternate reads.
            let project = ProjectInfo(name: " Song\n", filePath: "/tmp/Song.logicx ")

            let mixerFirst = await Server(project: project)
            var mixerFirstReferences: [String] = []
            mixerFirstReferences.append(try await mixerFirst.readMixerProjectReference())
            try await mixerFirst.expectCurrent(mixerFirstReferences.last)
            mixerFirstReferences.append(try await mixerFirst.readProjectInfoReference())
            try await mixerFirst.expectCurrent(mixerFirstReferences.last)
            mixerFirstReferences.append(try await mixerFirst.readMixerProjectReference())
            try await mixerFirst.expectCurrent(mixerFirstReferences.last)
            #expect(Set(mixerFirstReferences).count == 1)
            for reference in mixerFirstReferences {
                try await mixerFirst.expectCurrent(reference)
            }

            let projectInfoFirst = await Server(project: project)
            var projectInfoFirstReferences: [String] = []
            projectInfoFirstReferences.append(try await projectInfoFirst.readProjectInfoReference())
            try await projectInfoFirst.expectCurrent(projectInfoFirstReferences.last)
            projectInfoFirstReferences.append(try await projectInfoFirst.readMixerProjectReference())
            try await projectInfoFirst.expectCurrent(projectInfoFirstReferences.last)
            #expect(Set(projectInfoFirstReferences).count == 1)

            let reference = try #require(mixerFirstReferences.first)
            #expect(reference.hasPrefix("prj_"))
            let binding = try #require(await mixerFirst.registry.resolveCurrentProject(TargetReference(rawValue: reference)))
            #expect(binding.descriptor == TargetDescriptor.project(name: "Song", filePath: "/tmp/Song.logicx", epoch: 0))
        }
    }

    @Test("a mixer read without a cached bundle path reports the project as unobserved in either order")
    func aMixerReadWithoutACachedProjectPathReportsTheProjectAsUnobserved() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let clause = "project identity not yet observed: the cache carries no project name and bundle path"
            let cases: [(label: String, project: ProjectInfo?)] = [
                ("name only", ProjectInfo(name: "Song", filePath: nil)),
                ("blank path", ProjectInfo(name: "Song", filePath: "  ")),
                ("never polled", nil),
            ]
            for (label, project) in cases {
                for projectInfoFirst in [false, true] {
                    let server = await Server(project: project)
                    if projectInfoFirst {
                        let data = try await server.readProjectInfoData()
                        #expect(data["project_ref"] == nil, "\(label)")
                    }
                    for _ in 0..<2 {
                        let graph = try await server.readGraph()
                        #expect(graph.projectReference == nil, "\(label)")
                        let partialReason = try #require(graph.partialReason)
                        let clauses = partialReason.components(separatedBy: "; ")
                        #expect(clauses.contains(clause), "\(label): \(partialReason)")
                        #expect(!partialReason.contains("project reference is unavailable"), "\(label)")
                    }
                    #expect(await server.registry.currentProjectIdentity == nil, "\(label)")
                }
            }
        }
    }

    @Test("a snapshot that went stale during project issuance is thrown, never published as a missing reference")
    func aStaleSnapshotDuringProjectIssuanceFailsLoud() async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        await registry.bumpProjectEpoch()

        let issuance = await ProjectReferenceIssuance.issue(
            name: "Song",
            filePath: "/tmp/Song.logicx",
            registry: registry,
            snapshot: snapshot
        )
        guard case .stale = issuance else {
            Issue.record("expected .stale, got \(issuance)")
            return
        }
        #expect(await registry.currentProjectIdentity == nil)
        #expect(throws: MCPError.internalError("project target snapshot became stale during resource emission")) {
            try ResourceHandlers.routingProjectBinding(for: issuance)
        }
    }

    /// One fresh server: its own cache and registry. `project: nil` leaves the project section unpolled.
    private struct Server {
        let cache = StateCache()
        let registry = TargetRegistry()
        let router = ChannelRouter()

        init(project: ProjectInfo?) async {
            if let project {
                await cache.updateProject(project)
            }
        }

        func readProjectInfoData() async throws -> [String: Any] {
            let result = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: router,
                targetRegistry: registry,
                fileReader: .unavailable
            )
            return try #require(sharedJSONObject(sharedResourceText(result))?["data"] as? [String: Any])
        }

        func readProjectInfoReference() async throws -> String {
            try #require(try await readProjectInfoData()["project_ref"] as? String)
        }

        func readGraph() async throws -> RoutingGraph {
            let result = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let body = try #require(sharedJSONObject(sharedResourceText(result)))
            let graphObject = try #require(body["routing_graph"] as? [String: Any])
            return try JSONDecoder().decode(
                RoutingGraph.self,
                from: JSONSerialization.data(withJSONObject: graphObject)
            )
        }

        func readMixerProjectReference() async throws -> String {
            try #require(try await readGraph().projectReference).rawValue
        }

        func expectCurrent(_ reference: String?) async throws {
            let reference = try #require(reference)
            let binding = await registry.resolveCurrentProject(TargetReference(rawValue: reference))
            #expect(binding != nil, "\(reference) is not the current project reference")
        }
    }
}
