import Foundation
import Testing
@testable import LogicProMCP

@Suite("T3: resolvePath + selectByPath")
struct LibraryAccessorResolvePathTests {

    // -- parsePath tests --

    @Test func testParsePath_SimpleTwoSegment() async throws {
        let parts = LibraryAccessor.parsePath("Bass/Sub Bass")
        #expect(parts == ["Bass", "Sub Bass"])
    }

    @Test func testParsePath_EscapedSlash() async throws {
        // "Bass\/Sub" → literal single segment "Bass/Sub"
        let parts = LibraryAccessor.parsePath(#"Bass\/Sub"#)
        #expect(parts == ["Bass/Sub"])
    }

    @Test func testParsePath_TrailingSlashStripped() async throws {
        let parts = LibraryAccessor.parsePath("Bass/")
        #expect(parts == ["Bass"])
    }

    @Test func testParsePath_EmptyPath_Nil() async throws {
        #expect(LibraryAccessor.parsePath("") == nil)
        #expect(LibraryAccessor.parsePath("   ") == nil)
    }

    @Test func testParsePath_EmptySegment_Nil() async throws {
        #expect(LibraryAccessor.parsePath("A//C") == nil)
    }

    @Test func testParsePath_DisambiguatedIndex_Kept() async throws {
        let parts = LibraryAccessor.parsePath("Synth/Pad[1]")
        #expect(parts == ["Synth", "Pad[1]"])
    }

    // -- resolvePath from cached LibraryRoot --

    private func sampleRoot() -> LibraryRoot {
        // Root → Bass [Sub, Funky], Orch → Strings [Warm, Bright] (depth-3), Synth → Pad[0], Pad[1]
        let warm = LibraryNode(name: "Warm", path: "Orch/Strings/Warm", kind: .leaf, children: [])
        let bright = LibraryNode(name: "Bright", path: "Orch/Strings/Bright", kind: .leaf, children: [])
        let strings = LibraryNode(name: "Strings", path: "Orch/Strings", kind: .folder, children: [warm, bright])
        let orch = LibraryNode(name: "Orch", path: "Orch", kind: .folder, children: [strings])

        let sub = LibraryNode(name: "Sub", path: "Bass/Sub", kind: .leaf, children: [])
        let funky = LibraryNode(name: "Funky", path: "Bass/Funky", kind: .leaf, children: [])
        let bass = LibraryNode(name: "Bass", path: "Bass", kind: .folder, children: [sub, funky])

        let p0 = LibraryNode(name: "Pad", path: "Synth/Pad[0]", kind: .leaf, children: [])
        let p1 = LibraryNode(name: "Pad", path: "Synth/Pad[1]", kind: .leaf, children: [])
        let synth = LibraryNode(name: "Synth", path: "Synth", kind: .folder, children: [p0, p1])

        // Literal-slash preset for escape test
        let weird = LibraryNode(name: "Sub/Thing", path: #"Foo/Sub\/Thing"#, kind: .leaf, children: [])
        let foo = LibraryNode(name: "Foo", path: "Foo", kind: .folder, children: [weird])

        let r = LibraryNode(name: "(library-root)", path: "", kind: .folder, children: [bass, orch, synth, foo])
        return LibraryRoot(
            generatedAt: "2026-04-12T00:00:00Z",
            scanDurationMs: 0, measuredSettleDelayMs: 0,
            selectionRestored: false,
            truncatedBranches: 0, probeTimeouts: 0, cycleCount: 0,
            nodeCount: 12, leafCount: 6, folderCount: 5,
            root: r,
            categories: ["Bass", "Orch", "Synth", "Foo"],
            presetsByCategory: [:]
        )
    }

    @Test func testResolvePath_Depth1Leaf() async throws {
        let r = LibraryAccessor.resolvePath("Bass/Sub", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == true)
        #expect(r!.kind == .leaf)
        #expect(r!.matchedPath == "Bass/Sub")
    }

    @Test func testResolvePath_Depth3Leaf() async throws {
        let r = LibraryAccessor.resolvePath("Orch/Strings/Warm", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.kind == .leaf)
        #expect(r!.matchedPath == "Orch/Strings/Warm")
    }

    @Test func testResolvePath_MissingLeaf_NotExists() async throws {
        let r = LibraryAccessor.resolvePath("Bass/Nope", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == false)
        #expect(r!.kind == nil)
    }

    @Test func testResolvePath_EscapedSlash() async throws {
        let r = LibraryAccessor.resolvePath(#"Foo/Sub\/Thing"#, in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == true)
        #expect(r!.kind == .leaf)
    }

    @Test func testResolvePath_DisambiguatedDuplicate() async throws {
        let r = LibraryAccessor.resolvePath("Synth/Pad[1]", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == true)
        #expect(r!.kind == .leaf)
        #expect(r!.matchedPath == "Synth/Pad[1]")
    }

    @Test func testResolvePath_FolderPath_KindFolder() async throws {
        let r = LibraryAccessor.resolvePath("Orch", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == true)
        #expect(r!.kind == .folder)
        #expect((r!.children ?? []).contains("Strings"))
    }

    @Test func testResolvePath_EmptyPath_NotExists() async throws {
        let r = LibraryAccessor.resolvePath("", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == false)
    }

    @Test func testResolvePath_EmptySegment_NotExists() async throws {
        let r = LibraryAccessor.resolvePath("A//C", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == false)
    }

    @Test func testResolvePath_TrailingSlash() async throws {
        let r = LibraryAccessor.resolvePath("Bass/", in: sampleRoot())
        #expect(r != nil)
        #expect(r!.exists == true)
        #expect(r!.kind == .folder)
    }

    // -- selectByPath click sequence tests --

    @Test func testSelectByPath_ClickSequence_InOrder() async throws {
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder)
        let ok = await LibraryAccessor.selectByPath("Orch/Strings/Warm", settleDelayMs: 100, runtime: runtime)
        #expect(ok)
        let recorded = await recorder.calls
        #expect(recorded == ["Orch", "Strings", "Warm"])
    }

    @Test func testSelectByPath_AbortOnMissingIntermediate() async throws {
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder, missingAfter: 1)
        let ok = await LibraryAccessor.selectByPath("A/B/C", settleDelayMs: 0, runtime: runtime)
        #expect(!ok)
        // Only the first two clicks should have been attempted before abort
        let recorded = await recorder.calls
        #expect(recorded.count <= 2)
    }

    @Test func testSelectByPath_SettleDelayBetweenClicks() async throws {
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder)
        _ = await LibraryAccessor.selectByPath("A/B", settleDelayMs: 200, runtime: runtime)
        let sleeps = await recorder.sleeps
        #expect(sleeps.filter { $0 >= 200 }.count >= 1)
    }

    @Test func testSelectByPath_LegacyCategoryPresetStillWorks() async throws {
        // Legacy caller uses setInstrument(category:preset:) — functionally same as path "Cat/Preset".
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder)
        let ok = await LibraryAccessor.selectByPath("Cat/Preset", settleDelayMs: 0, runtime: runtime)
        #expect(ok)
        let recorded = await recorder.calls
        #expect(recorded == ["Cat", "Preset"])
    }

    // v3.0.4 — 3-segment N-column path (Isaac's actual live bug repro).
    // Pre-3.0.4 setTrackInstrument dropped middle segments; this test locks
    // the fix at the selectByPath level (which is what the production
    // setTrackInstrument now delegates to via LibraryAccessor.selectPath).
    @Test func testSelectByPath_ThreeSegment_Synthesizer_Bass_AcidEtchedBass() async throws {
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder)
        let ok = await LibraryAccessor.selectByPath(
            "Synthesizer/Bass/Acid Etched Bass", settleDelayMs: 0, runtime: runtime
        )
        #expect(ok)
        let recorded = await recorder.calls
        #expect(recorded == ["Synthesizer", "Bass", "Acid Etched Bass"],
                "v3.0.4 must click every segment in order — not parts[0]+parts[last]")
    }

    // v3.0.4 — 4-segment path (defence-in-depth: confirms the walker isn't
    // hardcoded to exactly 3 levels).
    @Test func testSelectByPath_FourSegment_DeepPath() async throws {
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder)
        let ok = await LibraryAccessor.selectByPath(
            "Orchestral/Strings/Violins/Warm Legato", settleDelayMs: 0, runtime: runtime
        )
        #expect(ok)
        let recorded = await recorder.calls
        #expect(recorded == ["Orchestral", "Strings", "Violins", "Warm Legato"])
    }

    // v3.0.4 — middle-segment failure aborts, confirming no silent skip.
    @Test func testSelectByPath_ThreeSegment_MissingMiddle_Aborts() async throws {
        let recorder = ClickRecorder()
        let runtime = makeSelectByPathRuntime(recorder: recorder, missingAfter: 1)
        let ok = await LibraryAccessor.selectByPath(
            "Synthesizer/MissingSubfolder/Whatever", settleDelayMs: 0, runtime: runtime
        )
        #expect(!ok, "missing intermediate segment must fail fast")
        let recorded = await recorder.calls
        #expect(recorded.count <= 2,
                "should abort before clicking the final segment when middle is missing")
    }
}

// MARK: - Test helpers

private actor ClickRecorder {
    var calls: [String] = []
    var sleeps: [Int] = []
    func recordClick(_ name: String) { calls.append(name) }
    func recordSleep(_ ms: Int) { sleeps.append(ms) }
}

private func makeSelectByPathRuntime(recorder: ClickRecorder, missingAfter: Int? = nil) -> LibraryAccessor.PathRuntime {
    return LibraryAccessor.PathRuntime(
        clickByName: { name in
            await recorder.recordClick(name)
            if let m = missingAfter, await recorder.calls.count > m {
                return false   // intermediate node "not found"
            }
            return true
        },
        sleep: { ms in
            await recorder.recordSleep(ms)
        }
    )
}
