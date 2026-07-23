import Foundation

// ADR-014 / #302 R1 — sealed independent-expected proof + verify guard (DARK CORE).
//
// This introduces the TYPE + independence guard that lets #293's deferred positive
// match become grant-able; it is dark: no production caller, no public API, feature
// flag off. The proven `IndependentExpectedProof` case compiles ONLY under
// `QUALIFICATION_FAULT_SEAM`, so a release build has only `.unproven` and
// `verifyRegion` can never grant a positive match in release. The live ingestion that
// mints a proof from a real independent source — write-oracle (pre-authored write
// intent) or dual-observation (a distinct Logic→notes surface such as a controlled
// export) — is R2. `SMFReader` is a decoder, not the root of trust: the root of trust
// is the surface that produced the expected notes. See PRD-issue-302 and the ADR-014
// design record.

/// Independent-source class of an expected sequence (provenance taxonomy). The cases
/// are distinct and non-interchangeable, and are distinct from the OBSERVED conversion
/// (`MIDIReadbackProvenance.eventListAX`); an expected/manifest is never the observed.
enum IndependentExpectedRoot: String, Sendable, Equatable {
    case authoredIntent    // write-oracle: pre-authored write intent (import / record_sequence)
    case controlledExport  // dual-observation: a distinct Logic→notes surface
}

enum RegionMatchVerdict: Equatable, Sendable {
    case exactMatch
    case mismatch(added: [MIDINoteEvent], removed: [MIDINoteEvent])
    case incompleteCannotVerify(reason: String)
}

/// Sealed, non-forgeable proof that an expected sequence came from an independent
/// root of trust — a source never derived from the observed conversion. No
/// public/internal initializer, factory, or decoder;
/// the proven case compiles only under the debug seam; a decoded or label-only
/// expected can never present one. Binds the independent root + region identity + a
/// content digest of the expected notes/PPQ.
enum IndependentExpectedProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case proven(SealedIndependentExpected)
    #endif

    /// Release-safe extraction: the independent payload, or nil when not proven — nil
    /// in every release build (the proven case does not compile there). Returning a
    /// tuple avoids naming the seam-only type in a release-compiled signature.
    var independentPayload: (
        root: IndependentExpectedRoot, rootID: String, region: MIDIRegionReference,
        notes: [MIDINoteEvent], ppq: Int, contentBinding: String
    )? {
        #if QUALIFICATION_FAULT_SEAM
        if case let .proven(s) = self {
            return (s.root, s.rootID, s.region, s.expectedNotes, s.expectedPPQ, s.contentBinding)
        }
        #endif
        return nil
    }
}

#if QUALIFICATION_FAULT_SEAM
/// Opaque payload: the initializer is fileprivate to THIS file, so no other file
/// (including a `@testable` importer, which does not open `fileprivate`) can construct
/// one. The sole mint is `IndependentExpectedSeam` below; R2 replaces that seam with a
/// live ingestion boundary that decodes the notes from the independent source itself.
struct SealedIndependentExpected: Sendable, Equatable {
    let root: IndependentExpectedRoot
    let rootID: String
    fileprivate let region: MIDIRegionReference
    fileprivate let expectedNotes: [MIDINoteEvent]
    fileprivate let expectedPPQ: Int
    fileprivate let contentBinding: String

    fileprivate init(
        root: IndependentExpectedRoot, rootID: String,
        region: MIDIRegionReference, notes: [MIDINoteEvent], ppq: Int
    ) {
        self.root = root
        self.rootID = rootID
        self.region = region
        self.expectedNotes = notes
        self.expectedPPQ = ppq
        self.contentBinding = midiRegionNoteDigest(notes, ppq: ppq)
    }
}

/// The sole mint of a proven `IndependentExpectedProof` in R1 (debug seam). Stands in
/// for R2's live ingestion boundary; a release build has no minter.
enum IndependentExpectedSeam {
    static func mint(
        root: IndependentExpectedRoot, rootID: String,
        region: MIDIRegionReference, notes: [MIDINoteEvent], ppq: Int
    ) -> IndependentExpectedProof {
        .proven(SealedIndependentExpected(root: root, rootID: rootID, region: region, notes: notes, ppq: ppq))
    }
}
#endif

/// Verify an OBSERVED complete snapshot against an INDEPENDENT expected proof. Grants
/// `.exactMatch` only when the expected carries a sealed independent proof whose root
/// differs from the observed conversion, is bound to the same region, and whose
/// (canonicalized, PPQ-normalized) notes equal the observed notes. In a release build
/// `independentPayload` is always nil, so this never grants a match.
func verifyRegion(observed: MIDIRegionNoteSnapshot, expected: IndependentExpectedProof) -> RegionMatchVerdict {
    guard observed.complete else {
        return .incompleteCannotVerify(reason: "observed readback is not complete")
    }
    guard let independent = expected.independentPayload else {
        return .incompleteCannotVerify(reason: "expected must carry a sealed independent provenance proof")
    }
    // Independence: the expected's root must differ from the observed conversion.
    guard independent.rootID != observed.conversionPipelineID else {
        return .incompleteCannotVerify(reason: "expected root shares the observed conversion pipeline")
    }
    // Region-identity binding.
    guard independent.region == observed.regionReference else {
        return .incompleteCannotVerify(reason: "expected proof is not bound to the observed region")
    }
    // Content-binding integrity (a proof cannot be relabeled onto foreign notes).
    guard independent.contentBinding == midiRegionNoteDigest(independent.notes, ppq: independent.ppq) else {
        return .incompleteCannotVerify(reason: "expected proof content binding is invalid")
    }
    guard observed.ppq > 0, independent.ppq > 0 else {
        return .incompleteCannotVerify(reason: "PPQ must be positive")
    }
    let actual = canonicalize(observed.notes, ppq: observed.ppq)
    guard let normalized = normalizePPQ(independent.notes, from: independent.ppq, to: observed.ppq) else {
        return .incompleteCannotVerify(reason: "PPQ normalization overflow")
    }
    let wanted = canonicalize(normalized, ppq: observed.ppq)
    guard actual != wanted else { return .exactMatch }

    // Duplicate-preserving multiset diff.
    var unmatched = wanted
    var added: [MIDINoteEvent] = []
    for note in actual {
        if let index = unmatched.firstIndex(of: note) {
            unmatched.remove(at: index)
        } else {
            added.append(note)
        }
    }
    return .mismatch(added: added, removed: unmatched)
}
