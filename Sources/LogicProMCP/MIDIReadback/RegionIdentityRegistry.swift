import Foundation

// Dedicated file for the query↔identity binding proof used by the MIDI note
// readback assessment. `RegistryResolvedIdentityProof` binds a requested region
// reference to the identity the registry resolved it to, so the assessment
// chokepoint can (1) verify the proof resolves the SAME query it was handed and
// (2) field-compare the resolved identity against the independently observed
// identity — never trusting a caller-supplied "this identity matches" claim.
//
// Mint discipline: the initializer is fileprivate to THIS file; there
// is no Decodable conformance and no general-purpose factory. A caller therefore
// cannot forge a proof that binds an arbitrary identity to an arbitrary region.
// This build ships no production resolver; the only mint is the debug-only seam
// below, so production evidence cannot carry a resolved identity at all.

struct RegistryResolvedIdentityProof: Sendable {
    let boundRegion: MIDIRegionReference
    let identity: ResolvedRegionIdentity

    fileprivate init(boundRegion: MIDIRegionReference, identity: ResolvedRegionIdentity) {
        self.boundRegion = boundRegion
        self.identity = identity
    }
}

#if QUALIFICATION_FAULT_SEAM
enum RegionIdentityRegistrySeam {
    /// Test-only mint. This is a test seam, NOT a security boundary: it is
    /// compiled solely under `QUALIFICATION_FAULT_SEAM` (debug), so a release
    /// binary has no path to construct the proof.
    static func mint(
        boundRegion: MIDIRegionReference,
        identity: ResolvedRegionIdentity
    ) -> RegistryResolvedIdentityProof {
        RegistryResolvedIdentityProof(boundRegion: boundRegion, identity: identity)
    }
}
#endif
