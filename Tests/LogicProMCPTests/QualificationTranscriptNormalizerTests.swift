import Foundation
import Testing
@testable import LogicProMCP

// #394 — the same-artifact qualification now attests the SHIPPED DEFAULT for
// ADR-002 target_ref (default ON) instead of the `=0` kill-switch. That surfaces
// session-random target refs (trk_/mix_/ins_/prj_ + UUID) and trace ids (lpmcp_
// + UUID) in the transcript, so `QualificationTranscriptNormalizer` rewrites them
// to appearance-order placeholders — making the transcript CROSS-RUN ID-STABLE
// (the ID dimension only; a real live run's timestamp / DAW-state noise is not
// touched by this pass, so a whole live transcript is not byte-identical). These
// tests prove the ID normalization on synthetic frames that differ ONLY in ids.
//
// SPELLING IS LOAD-BEARING: every Bool assertion below is a BARE `#expect(x)` /
// `#expect(!x)`, and every optional is unwrapped with `#require`. Under this
// toolchain `#expect(<Bool> == true/false)`, `?? false` and `== .some(true)` are
// DEAD and pass unconditionally. Value equality between non-Bool types
// (`#expect(a == b)` over String/Data/[QualificationWireFrame]) is live and used
// deliberately.
@Suite("Qualification transcript normalization (#394)")
struct QualificationTranscriptNormalizerTests {

    // MARK: (a) cross-run ID stability — two runs, ids differ only, identical transcript

    @Test("two runs differing only in random ids yield an identical ID-normalized transcript")
    func normalizedTranscriptIsByteStableAcrossRuns() throws {
        let run1 = Self.transcript(
            track: "A1B2C3D4-E5F6-4A0B-8C1D-2E3F4A5B6C7D",
            insert: "11111111-2222-4333-8444-555566667777",
            trace: "99999999-8888-4777-8666-555544443333"
        )
        let run2 = Self.transcript(
            track: "FFFFFFFF-EEEE-4DDD-8CCC-BBBBAAAA9999",
            insert: "00000000-1111-4222-8333-444455556666",
            trace: "12345678-9ABC-4DEF-8012-3456789ABCDE"
        )

        // Sanity: the two runs really do differ (different random UUIDs).
        #expect(run1 != run2)

        let norm1 = QualificationTranscriptNormalizer.normalize(run1)
        let norm2 = QualificationTranscriptNormalizer.normalize(run2)

        // Structural equality across runs…
        #expect(norm1 == norm2)

        // …and byte equality of the encoded transcript artifact.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data1 = try encoder.encode(norm1)
        let data2 = try encoder.encode(norm2)
        #expect(data1 == data2)

        // The random ids are gone and replaced with stable placeholders.
        let joined = norm1.map(\.payload).joined()
        #expect(joined.contains("trk_<NORM:0>"))
        #expect(joined.contains("ins_<NORM:0>"))
        #expect(joined.contains("lpmcp_<NORM:0>"))
        #expect(!joined.contains("A1B2C3D4"))

        // Referential integrity: the track ref a resource EMITTED (frame 1) and
        // the ref a later op ADDRESSED (frame 2) are the SAME raw UUID, so they
        // normalize to the SAME placeholder — the transcript still shows they
        // name the same track.
        #expect(norm1[1].payload.contains("trk_<NORM:0>"))
        #expect(norm1[2].payload.contains("trk_<NORM:0>"))
    }

    @Test("the ID pass is load-bearing — un-normalized transcripts differing only in ids are NOT identical")
    func rawTranscriptIsNotByteStable() throws {
        // Guards the reproducibility claim above against a no-op normalizer: the
        // RAW transcripts must differ, so their equality can only come from the
        // normalization pass, not from the fixtures being identical to begin with.
        let run1 = Self.transcript(
            track: "A1B2C3D4-E5F6-4A0B-8C1D-2E3F4A5B6C7D",
            insert: "11111111-2222-4333-8444-555566667777",
            trace: "99999999-8888-4777-8666-555544443333"
        )
        let run2 = Self.transcript(
            track: "FFFFFFFF-EEEE-4DDD-8CCC-BBBBAAAA9999",
            insert: "00000000-1111-4222-8333-444455556666",
            trace: "12345678-9ABC-4DEF-8012-3456789ABCDE"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(run1) != encoder.encode(run2))
    }

    // MARK: (b) the oracle is not blinded by normalization

    @Test("normalization keeps a wrong / stale target ref distinguishable")
    func normalizationPreservesTargetFaithfulness() {
        let emitted = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let stale = "11111111-2222-4333-8444-555566667777"

        let right = Self.targetPair(emitted: emitted, addressed: emitted)
        let wrong = Self.targetPair(emitted: emitted, addressed: stale)

        // On the RAW transcript: right target agrees, wrong/stale does not.
        #expect(Self.targetVerdict(right))
        #expect(!Self.targetVerdict(wrong))

        // After normalization the verdicts are UNCHANGED — normalization neither
        // fabricated agreement (a wrong target stays wrong) nor destroyed it (a
        // right target stays right).
        #expect(Self.targetVerdict(QualificationTranscriptNormalizer.normalize(right)))
        #expect(!Self.targetVerdict(QualificationTranscriptNormalizer.normalize(wrong)))
    }

    @Test("the semantic oracle reads raw response bytes, so ref normalization cannot blind it")
    func semanticOracleReadsRawBytes() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.systemGetTrace])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.systemGetTrace])

        // The oracle passes the faithful, right-target trace…
        let good = try #require(oracle.evaluate(
            responseData: fixture.responseData,
            readbackData: fixture.readbackData
        ))
        #expect(good)

        // …and CATCHES a trace for the WRONG operation/target.
        let wrongResponse = fixture.response.replacingOccurrences(
            of: #""operation_id":"system.saga_execute""#,
            with: #""operation_id":"transport.play""#
        )
        let wrong = try #require(oracle.evaluate(
            responseData: Data(wrongResponse.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!wrong)

        // The transcript normalizer WOULD rewrite this response's random trace id
        // (proving normalization is active on this content), but the oracle
        // verdicts above were computed from the RAW response bytes — a different
        // data path from the transcript. So normalization cannot blind the oracle.
        let normalized = QualificationTranscriptNormalizer.normalizeString(fixture.response)
        #expect(normalized.contains("lpmcp_<NORM:0>"))
        #expect(!normalized.contains("lpmcp_00000000-0000-0000-0000-000000000000"))
    }

    // MARK: (c) the qualification attests the shipped default (ADR-002 default-ON)

    @Test("qualification env attests the ADR-002 shipped default, not the =0 kill-switch")
    func qualificationEnvironmentAttestsShippedDefault() throws {
        // Even a base that inherited a `=0` pin must be attested at the shipped
        // default: the harness strips the pin so it runs what production runs.
        let base = ["PATH": "/usr/bin", "LOGIC_MCP_ADR002_TARGET_REF": "0"]
        let env = QualificationTransport.qualificationEnvironment(base: base)

        // Shipped default = the variable ABSENT; the server reads absent as ON.
        #expect(!env.keys.contains("LOGIC_MCP_ADR002_TARGET_REF"))
        let readsOn = (env["LOGIC_MCP_ADR002_TARGET_REF"] ?? "") != "0"
        #expect(readsOn)

        // Companion pins stay at their shipped-default behavior.
        let strict = try #require(env["LOGIC_MCP_ADR003_STRICT_PARAMS"])
        #expect(strict == "1")
        let trace = try #require(env["LOGIC_MCP_ADR005_OPERATION_TRACE"])
        #expect(trace == "1")

        // Unrelated base entries are preserved.
        let path = try #require(env["PATH"])
        #expect(path == "/usr/bin")
    }

    @Test("the =0 kill-switch stays covered as a named, secondary qualification env")
    func killSwitchEnvironmentRemainsCovered() throws {
        let env = QualificationTransport.adr002KillSwitchEnvironment(base: [:])
        // "0" is the exact documented kill-switch spelling FeatureFlags reads as
        // OFF (see FeatureFlagEnvironmentTests); this keeps that path attested.
        let flag = try #require(env["LOGIC_MCP_ADR002_TARGET_REF"])
        #expect(flag == "0")
        let readsOff = (env["LOGIC_MCP_ADR002_TARGET_REF"] ?? "") == "0"
        #expect(readsOff)
        // The secondary env is a faithful sibling of the primary.
        let strict = try #require(env["LOGIC_MCP_ADR003_STRICT_PARAMS"])
        #expect(strict == "1")
    }

    // MARK: - fixtures

    /// A three-frame transcript: a trace-id request, a readback response that
    /// EMITS a track ref + an insert ref, and a probe that ADDRESSES the same
    /// track ref. Only the UUID values vary between runs.
    private static func transcript(
        track: String,
        insert: String,
        trace: String
    ) -> [QualificationWireFrame] {
        [
            QualificationWireFrame(
                sequence: 0,
                direction: .request,
                operationID: "trace_get",
                payload: #"{"id":7,"jsonrpc":"2.0","method":"tools/call","params":{"trace_id":"lpmcp_\#(trace)"}}"#
            ),
            QualificationWireFrame(
                sequence: 1,
                direction: .response,
                operationID: "operation-readback-9",
                payload: #"{"id":9,"jsonrpc":"2.0","result":[{"track_ref":"trk_\#(track)","inserts":[{"insert_ref":"ins_\#(insert)"}]}]}"#
            ),
            QualificationWireFrame(
                sequence: 2,
                direction: .request,
                operationID: "operation_probe.tracks.select",
                payload: #"{"id":10,"jsonrpc":"2.0","params":{"target_ref":"trk_\#(track)"}}"#
            ),
        ]
    }

    private static func targetPair(emitted: String, addressed: String) -> [QualificationWireFrame] {
        [
            QualificationWireFrame(
                sequence: 0,
                direction: .response,
                operationID: "readback",
                payload: #"{"jsonrpc":"2.0","result":{"track_ref":"trk_\#(emitted)"}}"#
            ),
            QualificationWireFrame(
                sequence: 1,
                direction: .request,
                operationID: "probe",
                payload: #"{"jsonrpc":"2.0","params":{"target_ref":"trk_\#(addressed)"}}"#
            ),
        ]
    }

    /// A stand-in for a target-faithfulness oracle: does the ref the op addressed
    /// (frame 1) equal the ref the resource emitted (frame 0)?
    private static func targetVerdict(_ frames: [QualificationWireFrame]) -> Bool {
        guard let emitted = firstTrackToken(in: frames[0].payload),
              let addressed = firstTrackToken(in: frames[1].payload) else {
            return false
        }
        return emitted == addressed
    }

    private static func firstTrackToken(in payload: String) -> String? {
        guard let range = payload.range(of: #"trk_[^"]+"#, options: .regularExpression) else {
            return nil
        }
        return String(payload[range])
    }
}
