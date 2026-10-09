import Foundation
import Testing
@testable import LogicProMCP

// v3.1.8 (Issue #7) — LogicProjectFileReader.
// Reads `.logicx/Alternatives/000/MetaData.plist` for tempo / time signature /
// track count when Logic Pro 12.x's AppleScript dictionary doesn't expose these
// terms. Path validation is hardened per PRD §6.3 (realpath, `..` rejection,
// leaf-prefix check, mtime-jitter retry).

private func makeProjectBundle(
    name: String,
    tempo: Double? = 80,
    numerator: Int? = 4,
    denominator: Int? = 4,
    trackCount: Int? = 31,
    lastSavedFrom: String = "Logic Pro 12.0.1 (6590)",
    asXML: Bool = false,
    omitTrackCount: Bool = false,
    extraSize: Int = 0
) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-mcp-tests-\(UUID().uuidString)", isDirectory: true)
    let bundle = tmp.appendingPathComponent("\(name).logicx", isDirectory: true)
    let altDir = bundle
        .appendingPathComponent("Alternatives", isDirectory: true)
        .appendingPathComponent("000", isDirectory: true)
    try FileManager.default.createDirectory(at: altDir, withIntermediateDirectories: true)

    var dict: [String: Any] = [
        "Version": 3,
        "SampleRate": 48000,
        "LastSavedFrom": lastSavedFrom,
    ]
    if let tempo { dict["BeatsPerMinute"] = tempo }
    if let numerator { dict["SongSignatureNumerator"] = numerator }
    if let denominator { dict["SongSignatureDenominator"] = denominator }
    if !omitTrackCount, let trackCount { dict["NumberOfTracks"] = trackCount }
    if extraSize > 0 {
        dict["_padding"] = String(repeating: "x", count: extraSize)
    }

    let format: PropertyListSerialization.PropertyListFormat = asXML ? .xml : .binary
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
    let plistURL = altDir.appendingPathComponent("MetaData.plist")
    try data.write(to: plistURL)
    return bundle
}

private func cleanupBundle(_ bundle: URL) {
    let tmp = bundle.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: tmp)
}

private func runtimeForFixture(
    bundle: URL,
    now: Date = Date(timeIntervalSince1970: 1_730_000_000)
) -> LogicProjectFileReader.Runtime {
    LogicProjectFileReader.Runtime(
        currentDocumentPath: { bundle.path },
        now: { now },
        readPlistData: { url in FileManager.default.contents(atPath: url.path) },
        mtime: { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        },
        sleep: { _ in /* no-op in tests */ }
    )
}

// MARK: - Plist parsing

@Test
func parseMetaData_validBinaryPlist_returnsAllFields() async throws {
    let bundle = try makeProjectBundle(name: "ValidBinary", tempo: 80, trackCount: 31)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata != nil)
    #expect(metadata?.tempo == 80)
    #expect(metadata?.signatureNumerator == 4)
    #expect(metadata?.signatureDenominator == 4)
    #expect(metadata?.trackCount == 31)
    #expect(metadata?.timeSignatureString == "4/4")
}

@Test
func parseMetaData_xmlPlist_returnsAllFields() async throws {
    let bundle = try makeProjectBundle(name: "ValidXML", tempo: 110, asXML: true)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata?.tempo == 110)
    #expect(metadata?.signatureNumerator == 4)
}

@Test
func parseMetaData_missingTrackCount_returnsNilField() async throws {
    let bundle = try makeProjectBundle(name: "NoTrackCount", omitTrackCount: true)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata != nil)
    #expect(metadata?.trackCount == nil)
    #expect(metadata?.tempo == 80)
}

@Test
func parseMetaData_zeroSignature_returnsNilTimesig() async throws {
    let bundle = try makeProjectBundle(
        name: "ZeroSig", tempo: 90, numerator: 0, denominator: 0, trackCount: 1
    )
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata?.signatureNumerator == nil)
    #expect(metadata?.signatureDenominator == nil)
    #expect(metadata?.timeSignatureString == nil)
    #expect(metadata?.tempo == 90)
}

@Test
func parseMetaData_infiniteTempo_isDropped() async throws {
    // A non-finite BeatsPerMinute must never enter the cache/report — a +Inf
    // Double would make JSONEncoder throw downstream. The guard drops it so the
    // tempo field stays nil and the caller falls back to a safe default.
    let bundle = try makeProjectBundle(name: "InfTempo", tempo: Double.infinity, trackCount: 2)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata != nil)
    #expect(metadata?.tempo == nil)
    #expect(metadata?.trackCount == 2)
}

@Test
func parseMetaData_nanTempo_isDropped() async throws {
    let bundle = try makeProjectBundle(name: "NaNTempo", tempo: Double.nan, trackCount: 5)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata != nil)
    #expect(metadata?.tempo == nil)
    #expect(metadata?.trackCount == 5)
}

@Test
func parseMetaData_corruptBytes_returnsNil() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-mcp-corrupt-\(UUID().uuidString)", isDirectory: true)
    let bundle = tmp.appendingPathComponent("Corrupt.logicx", isDirectory: true)
    let altDir = bundle
        .appendingPathComponent("Alternatives", isDirectory: true)
        .appendingPathComponent("000", isDirectory: true)
    try FileManager.default.createDirectory(at: altDir, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0x00, 0x00]).write(to: altDir.appendingPathComponent("MetaData.plist"))
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata == nil)
}

@Test
func parseMetaData_oversize10MB_returnsNil() async throws {
    let bundle = try makeProjectBundle(name: "Huge", extraSize: 11 * 1024 * 1024)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata == nil)
}

@Test(arguments: [-1, 0, 1])
func productionMetadataReaderBoundsBytesBeforeParsing(limitDelta: Int) throws {
    let bundle = try makeProjectBundle(name: "BoundedProductionRead")
    defer { cleanupBundle(bundle) }
    let leaf = bundle.appendingPathComponent("Alternatives/000/MetaData.plist")
    let size = LogicProjectFileReader.maxPlistBytes + limitDelta
    try Data(repeating: 0x61, count: size).write(to: leaf)

    // Exercise the real file callback, not the injected whole-file fixture reader.
    let bytes = LogicProjectFileReader.Runtime.production.readPlistData(leaf)
    if limitDelta > 0 {
        #expect(bytes == nil)
    } else {
        #expect(bytes?.count == size)
        #expect(bytes?.first == 0x61)
        #expect(bytes?.last == 0x61)
    }
}

@Test(arguments: [false, true])
func productionMetadataReaderParsesValidPlists(asXML: Bool) async throws {
    let bundle = try makeProjectBundle(name: "ProductionPlist", tempo: 110, trackCount: 31, asXML: asXML)
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.readPath(bundle.path)
    #expect(metadata?.tempo == 110)
    #expect(metadata?.timeSignatureString == "4/4")
    #expect(metadata?.trackCount == 31)
}

@Test
func productionMetadataReaderRefusesMissingFileAndDirectory() throws {
    let bundle = try makeProjectBundle(name: "ProductionMissingFile")
    defer { cleanupBundle(bundle) }
    let missing = bundle.appendingPathComponent("missing.plist")
    #expect(LogicProjectFileReader.Runtime.production.readPlistData(missing) == nil)
    #expect(LogicProjectFileReader.Runtime.production.readPlistData(bundle) == nil)
}

// MARK: - Path validation

@Test
func path_rejectNonLogicx_returnsNil() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-mcp-nonlogicx-\(UUID().uuidString).txt", isDirectory: false)
    try Data("hello".utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let runtime = LogicProjectFileReader.Runtime(
        currentDocumentPath: { tmp.path },
        now: Date.init,
        readPlistData: { url in FileManager.default.contents(atPath: url.path) },
        mtime: { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        },
        sleep: { _ in }
    )
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata == nil)
}

@Test
func path_rejectDotDot_returnsNil() async throws {
    let bundle = try makeProjectBundle(name: "Legit")
    defer { cleanupBundle(bundle) }
    // Construct a path that contains ".." literally — even if it would normalise,
    // we reject pre-normalisation path components for defensive depth.
    let evilPath = bundle.deletingLastPathComponent().path + "/foo/../Legit.logicx"
    let runtime = LogicProjectFileReader.Runtime(
        currentDocumentPath: { evilPath },
        now: Date.init,
        readPlistData: { url in FileManager.default.contents(atPath: url.path) },
        mtime: { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        },
        sleep: { _ in }
    )
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata == nil)
}

@Test
func path_rejectLeafSymlinkEscape_returnsNil() async throws {
    let bundle = try makeProjectBundle(name: "Legit2")
    defer { cleanupBundle(bundle) }
    // Replace the actual MetaData.plist with a symlink to a file *outside* the bundle.
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-mcp-outside-\(UUID().uuidString).plist")
    try PropertyListSerialization
        .data(fromPropertyList: ["BeatsPerMinute": 999], format: .binary, options: 0)
        .write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }

    let leafPath = bundle.appendingPathComponent("Alternatives/000/MetaData.plist").path
    try? FileManager.default.removeItem(atPath: leafPath)
    try FileManager.default.createSymbolicLink(atPath: leafPath, withDestinationPath: outside.path)
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata == nil, "Symlink-escape must reject; got tempo=\(String(describing: metadata?.tempo))")
}

@Test
func path_normalizesPrivateUsers_acceptsBoth() async throws {
    let bundle = try makeProjectBundle(name: "Norm")
    defer { cleanupBundle(bundle) }
    // /tmp on macOS is actually a symlink to /private/tmp. Pass the resolved path.
    let resolvedPath = bundle.resolvingSymlinksInPath().path
    let runtime = LogicProjectFileReader.Runtime(
        currentDocumentPath: { resolvedPath },
        now: Date.init,
        readPlistData: { url in FileManager.default.contents(atPath: url.path) },
        mtime: { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        },
        sleep: { _ in }
    )
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata?.tempo == 80)
}

@Test
func path_koreanFilename_succeeds() async throws {
    let bundle = try makeProjectBundle(name: "무제테스트")
    defer { cleanupBundle(bundle) }
    let metadata = await LogicProjectFileReader.read(runtime: runtimeForFixture(bundle: bundle))
    #expect(metadata?.tempo == 80)
    #expect(metadata?.trackCount == 31)
}

// MARK: - mtime handling

@Test
func mtime_futureClamped_zero() async throws {
    let bundle = try makeProjectBundle(name: "FutureMtime")
    defer { cleanupBundle(bundle) }
    let leaf = bundle.appendingPathComponent("Alternatives/000/MetaData.plist")
    let futureDate = Date().addingTimeInterval(3600)
    try FileManager.default.setAttributes(
        [.modificationDate: futureDate], ofItemAtPath: leaf.path
    )
    let runtime = runtimeForFixture(bundle: bundle, now: Date())
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata != nil)
    let age = metadata!.lastSavedAgeSec(now: Date())
    #expect(age == 0, "future mtime should clamp; got \(age)")
}

@Test
func mtime_jitterRetry_recovers() async throws {
    let bundle = try makeProjectBundle(name: "JitterRecover")
    defer { cleanupBundle(bundle) }
    let leaf = bundle.appendingPathComponent("Alternatives/000/MetaData.plist")
    let baselineMtime = Date(timeIntervalSince1970: 1_700_000_000)
    let driftMtime = Date(timeIntervalSince1970: 1_700_000_001)
    let counter = MtimeCounter()
    let runtime = LogicProjectFileReader.Runtime(
        currentDocumentPath: { bundle.path },
        now: { Date(timeIntervalSince1970: 1_700_000_500) },
        readPlistData: { url in FileManager.default.contents(atPath: url.path) },
        mtime: { _ in
            // attempt 0: m1=baseline, m2=drift  →  jitter detected, retry
            // attempt 1: m1=baseline, m2=baseline → stable
            switch counter.next() {
            case 0: return baselineMtime
            case 1: return driftMtime  // jitter
            case 2: return baselineMtime
            case 3: return baselineMtime  // stable on retry
            default: return baselineMtime
            }
        },
        sleep: { _ in }
    )
    _ = leaf  // suppress unused
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata != nil, "should recover after one retry")
    #expect(metadata?.metadataMTime == baselineMtime)
}

@Test
func mtime_jitterPersistent_returnsNil() async throws {
    let bundle = try makeProjectBundle(name: "JitterPersist")
    defer { cleanupBundle(bundle) }
    let counter = MtimeCounter()
    let runtime = LogicProjectFileReader.Runtime(
        currentDocumentPath: { bundle.path },
        now: { Date() },
        readPlistData: { url in FileManager.default.contents(atPath: url.path) },
        mtime: { _ in
            // Always different → both attempts see jitter
            Date(timeIntervalSince1970: TimeInterval(counter.next()))
        },
        sleep: { _ in }
    )
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata == nil, "persistent jitter must fail")
}

@Test
func currentDocumentPath_nil_returnsNil() async {
    let runtime = LogicProjectFileReader.Runtime(
        currentDocumentPath: { nil },
        now: Date.init,
        readPlistData: { _ in nil },
        mtime: { _ in nil },
        sleep: { _ in }
    )
    let metadata = await LogicProjectFileReader.read(runtime: runtime)
    #expect(metadata == nil)
}

// MARK: - Helpers

final class MtimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = count
        count += 1
        return n
    }
}
