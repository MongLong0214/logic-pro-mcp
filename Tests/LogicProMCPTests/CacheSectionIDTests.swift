import Foundation
import Testing
@testable import LogicProMCP

/// What survives of the ADR-006 snapshot capsule's tests: the section list, which 12 production
/// call sites key on. The rest of that suite exercised `VersionedSnapshot`, `StateSource` and
/// `Completeness` — types with zero production callers, so the tests passed while proving nothing
/// about the product. They are retired with the types.
@Suite struct CacheSectionIDTests {
    @Test func cacheSectionsAreComplete() {
        #expect(CacheSectionID.allCases.map(\.rawValue) == [
            "transport",
            "tracks",
            "mixer",
            "project",
            "pluginInventory",
            "libraryInventory",
        ])
    }
}
