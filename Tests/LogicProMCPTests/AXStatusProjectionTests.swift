@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

// Focused coverage for the typed AX status projection shipped as an internal,
// caller-free API. References no K0 surface-resolver symbol by construction.
//
// Each test prints its expected and actual values with an EVIDENCE prefix so the
// receipt can carry observed values rather than a claim that they matched.
@Suite("AXStatusProjectionTests")
struct AXStatusProjectionTests {

    static let pinnedRaws: [Int32] = [-25200, -25201, -25202, -25204, -25205, -25208, -25211]

    @Test func rawValuePreservedForEveryPinnedStatus() {
        var recovered: [Int32] = []
        for raw in Self.pinnedRaws {
            guard let status = AXError(rawValue: raw) else { continue }
            switch AXHelpers.projectChildrenStatus(status, nil) {
            case .failure(let error):
                recovered.append(error.raw)
            case .success:
                recovered.append(0)
            }
        }
        print("EVIDENCE AC-1 expected=\(Self.pinnedRaws) actual=\(recovered) count=\(Self.pinnedRaws.count)")
        let sevenRawsPinned: Bool = (Self.pinnedRaws.count == 7)
        #expect(sevenRawsPinned)
        let everyRawPreserved: Bool = (recovered == Self.pinnedRaws)
        #expect(everyRawPreserved)
    }

    @Test func absentValueIsEmptySuccess() {
        var emptySuccess = false
        var observed = "failure"
        if case .success(let elements) = AXHelpers.projectChildrenStatus(.success, nil) {
            emptySuccess = elements.isEmpty
            observed = "success(count: \(elements.count))"
        }
        print("EVIDENCE AC-2 expected=success(count: 0) actual=\(observed)")
        let absentIsEmptySuccess: Bool = emptySuccess
        #expect(absentIsEmptySuccess)
    }

    @Test func malformedNonArrayIsUnreadable() {
        let projected = AXHelpers.projectChildrenStatus(.success, "10,20" as NSString)
        let malformedIsUnreadable: Bool
        if case .failure(let error) = projected {
            malformedIsUnreadable = error == .malformedChildren
        } else {
            malformedIsUnreadable = false
        }
        #expect(
            malformedIsUnreadable,
            "Mutation caught: return an empty success for a malformed successful AXChildren value; an undecodable subtree cannot prove absence."
        )
    }

    @Test func wellFormedChildrenProjectToExpectedElements() {
        let expected = [AXUIElementCreateSystemWide()]
        var actual: [AXUIElement] = []
        if case .success(let elements) = AXHelpers.projectChildrenStatus(.success, expected as CFArray) {
            actual = elements
        }
        print("EVIDENCE AC-4 expected=\(expected) actual=\(actual)")
        let projectsExpectedElements: Bool = (actual == expected)
        #expect(projectsExpectedElements)
    }

    @Test func productionRuntimeSeamIsAbsent() {
        let seam = AXHelpers.Runtime.production.childrenResult
        print("EVIDENCE AC-7 expected=nil actual=\(seam == nil ? "nil" : "non-nil")")
        let seamIsAbsent: Bool = (seam == nil)
        #expect(seamIsAbsent)
    }
}
