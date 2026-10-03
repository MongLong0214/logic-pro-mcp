import Foundation
import Testing
@testable import LogicProMCP

// #965 O3: the session audit observes the session through the inspection's producer
// (`SessionPopulationObservation.observe`). The project file reader asks Logic for its front
// document on its own, so the bundle it reads need not be the project the cache holds. The
// inspection kept that bundle's MetaData.plist track count only when the two paths name the same
// bundle; the audit took any front document's count, so a second open project with more tracks
// raised `track_readback_gap` against this project's rail.
//
// These tests write real bundle directories, because the reader validates the path on disk, and
// stub only the front-document query and the plist bytes.

private struct Bundles {
    let directory: URL
    let cached: URL
    let other: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpm-965-o3-\(UUID().uuidString)", isDirectory: true)
        cached = directory.appendingPathComponent("Song.logicx", isDirectory: true)
        other = directory.appendingPathComponent("Other.logicx", isDirectory: true)
        for bundle in [cached, other] {
            let alternative = bundle.appendingPathComponent("Alternatives/000", isDirectory: true)
            try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
            try Data().write(to: alternative.appendingPathComponent("MetaData.plist"))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A reader whose front document is `front` and whose MetaData.plist says `count` tracks.
private func reader(front: URL, count: Int) -> LogicProjectFileReader.Runtime {
    LogicProjectFileReader.Runtime(
        currentDocumentPath: { front.path },
        now: { Date(timeIntervalSince1970: 1_700_000_500) },
        readPlistData: { _ in
            try? PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": count], format: .binary, options: 0)
        },
        mtime: { _ in Date(timeIntervalSince1970: 1_700_000_000) },
        sleep: { _ in }
    )
}

/// The cache holding `Song` at `bundle`, with two tracks read from its rail.
private func cache(holding bundle: URL) async -> StateCache {
    let cache = StateCache()
    await cache.updateProject(ProjectInfo(name: "Song", filePath: bundle.path))
    await cache.updateTracks([
        TrackState(id: 0, name: "Bass", type: .audio),
        TrackState(id: 1, name: "Keys", type: .audio),
    ])
    return cache
}

/// A reader that runs `duringRead` inside its front-document query, as Logic's answer can arrive after the
/// poller has moved the cache, then names `front` (or no document when `front` is nil).
private func movingReader(front: URL?, count: Int,
                          duringRead: @escaping @Sendable () async -> Void) -> LogicProjectFileReader.Runtime {
    LogicProjectFileReader.Runtime(
        currentDocumentPath: {
            await duringRead()
            return front?.path
        },
        now: { Date(timeIntervalSince1970: 1_700_000_500) },
        readPlistData: { _ in
            try? PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": count], format: .binary, options: 0)
        },
        mtime: { _ in Date(timeIntervalSince1970: 1_700_000_000) },
        sleep: { _ in }
    )
}

private func gap(_ report: ProjectSessionAudit.AuditReport) -> ProjectSessionAudit.Finding? {
    report.findings.first { $0.id == "track_readback_gap" }
}

@Suite("#965 O3: the audit reads the session as the inspection does")
struct Issue965AuditReadsTheSharedObservationTests {
    @Test func anotherProjectsTrackCountRaisesNoGap() async throws {
        // Mutation killed: `buildAudit(cache:)` reading `LogicProjectFileReader.read(...)?.trackCount`
        // itself again, as it did before #965 O3 (the gap comes back).
        let bundles = try Bundles()
        defer { bundles.remove() }
        let cache = await cache(holding: bundles.cached)
        let other = reader(front: bundles.other, count: 5)

        let report = await ProjectSessionAudit.buildAudit(cache: cache, fileReader: other)

        #expect(gap(report) == nil, "\(gap(report).map { "\($0.evidence.values)" } ?? "")")
        let reading = await SessionPopulationObservation.observe(cache: cache, fileReader: other)
        #expect(reading.fileTrackCount == nil)
        #expect(reading.projectFileNotBound)
    }

    @Test func theCachedProjectsTrackCountStillRaisesTheGap() async throws {
        // The positive control: the same reader, naming the cached project's bundle, keeps the
        // cross-check. Mutation killed: the count dropped whatever the bundle (no gap here).
        let bundles = try Bundles()
        defer { bundles.remove() }
        let cache = await cache(holding: bundles.cached)
        let same = reader(front: bundles.cached, count: 5)

        let report = await ProjectSessionAudit.buildAudit(cache: cache, fileReader: same)

        let finding = try #require(gap(report))
        #expect(finding.evidence.values == ["file_track_count=5", "ax_track_count=2"])
    }

    @Test func aRailThatGrewDuringTheFileReadIsComparedAtItsNewCount() async throws {
        // #1096 review round 1, R965-1: the poller moves the cache while the reader awaits Logic.
        // Mutation killed: the cache read before the file read (the two rows read before the await are
        // compared with the five the file names, a false gap).
        let bundles = try Bundles()
        defer { bundles.remove() }
        let cache = await cache(holding: bundles.cached)
        let reader = movingReader(front: bundles.cached, count: 5) {
            await cache.updateTracks((0..<5).map { TrackState(id: $0, name: "Track \($0 + 1)", type: .audio) })
        }

        let report = await ProjectSessionAudit.buildAudit(cache: cache, fileReader: reader)

        #expect(gap(report) == nil, "\(gap(report).map { "\($0.evidence.values)" } ?? "")")
    }

    @Test func aDocumentThatClosedDuringTheFileReadIsReportedClosed() async throws {
        // R965-1's second case: the document closes while the reader awaits Logic and the reader names
        // none. Mutation killed: the cache read before the file read (the audit reports the open
        // document it read first).
        let bundles = try Bundles()
        defer { bundles.remove() }
        let cache = await cache(holding: bundles.cached)
        let reader = movingReader(front: nil, count: 5) { await cache.updateDocumentState(false) }

        let report = await ProjectSessionAudit.buildAudit(cache: cache, fileReader: reader)

        #expect(report.findings.contains { $0.id == "no_open_document" }, "\(report.findings.map(\.id))")
    }

    @Test func theInspectionAndTheAuditKeepTheSameCount() async throws {
        // One rule in one place: for each front document, the count the audit cross-checks is the
        // count the inspection's capture carries.
        let bundles = try Bundles()
        defer { bundles.remove() }
        for (front, expected) in [(bundles.cached, 5 as Int?), (bundles.other, nil)] {
            let cache = await cache(holding: bundles.cached)
            let runtime = reader(front: front, count: 5)
            let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: nil, fileReader: runtime)
            let report = await ProjectSessionAudit.buildAudit(cache: cache, fileReader: runtime)
            let audited = gap(report).flatMap { finding in
                finding.evidence.values.first { $0.hasPrefix("file_track_count=") }.flatMap { Int($0.dropFirst("file_track_count=".count)) }
            }
            #expect(capture.fileTrackCount == expected, "\(front.lastPathComponent)")
            #expect(audited == expected, "\(front.lastPathComponent)")
        }
    }
}
