import Foundation
import Testing
@testable import LogicProMCP

/// #373 — an `operationUnavailable` deferral must say what the operation said.
///
/// The detail this replaces asserted one cause for every read-only shortfall: that the probe sends
/// `[:]` and the operation refused for want of a parameter. Measured 2026-08-24, that is false for
/// the two operations it most needed to describe — `tracks.list_library` takes no parameters at all
/// and refuses with `channels_exhausted` / "Library panel not found. Open Library (Y) in Logic
/// Pro." The attestation was sending its reader to check parameters that do not exist, while the
/// operation had already named its precondition.
@Suite("QualificationUnavailableDetail")
struct QualificationUnavailableDetailTests {

    @Test("the measured refusal is quoted, code and precondition both")
    func measuredRefusalIsQuoted() {
        let detail = QualificationOperationResult.unavailableDetail(
            error: "channels_exhausted",
            hint: "Library panel not found. Open Library (Y) in Logic Pro.")
        #expect(detail.contains("channels_exhausted"))
        #expect(detail.contains("Library panel not found. Open Library (Y) in Logic Pro."))
        // The claim the old text made, which was wrong for this operation.
        #expect(!detail.contains("parameter"))
    }

    @Test("a refusal that named nothing says so rather than borrowing a cause")
    func silentRefusalStatesItsSilence() {
        let detail = QualificationOperationResult.unavailableDetail(error: String?.none, hint: String?.none)
        #expect(detail.contains("neither an error code nor a precondition"))
    }

    @Test("half an answer is reported as half, not completed by guesswork")
    func partialRefusalsAreNotFilledIn() {
        let codeOnly = QualificationOperationResult.unavailableDetail(
            error: "invalid_params", hint: String?.none)
        #expect(codeOnly.contains("invalid_params"))
        #expect(codeOnly.contains("named no precondition"))

        let hintOnly = QualificationOperationResult.unavailableDetail(
            error: String?.none, hint: "Open an instrument plugin window first.")
        #expect(hintOnly.contains("Open an instrument plugin window first."))
        #expect(!hintOnly.contains("refused with"))
    }

    @Test("whitespace-only fields count as absent, not as a quoted empty reason")
    func blankFieldsAreTreatedAsAbsent() {
        // A trailing-newline hint would otherwise render as `refused with `x`: ` — a colon
        // introducing nothing, which reads as a truncated message rather than a missing one.
        let detail = QualificationOperationResult.unavailableDetail(error: "  ", hint: "\n ")
        #expect(detail.contains("neither an error code nor a precondition"))
    }
}
