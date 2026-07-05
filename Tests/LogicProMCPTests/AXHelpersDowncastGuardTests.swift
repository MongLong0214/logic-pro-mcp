@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

/// WS3 AC3 — `AXHelpers` kAXChildren CFArray downcast guard (H-6 parity).
///
/// The production `children` closure previously `unsafeDowncast`-ed the raw
/// kAXChildren attribute to `CFArray` without a `CFGetTypeID` guard. A malformed
/// or mocked attribute that is NOT a CFArray would be undefined behavior (a
/// process crash), unlike getPosition/getSize which already guard their AXValue
/// casts. The guarded decode is extracted into `decodeChildrenArray` so it is
/// unit-testable without a live AX element.

/// A non-CFArray children attribute returns an empty list instead of crashing.
@Test func testDecodeChildrenArrayRejectsNonCFArrayValues() {
    #expect(AXHelpers.decodeChildrenArray(NSString(string: "not-an-array")).isEmpty)
    #expect(AXHelpers.decodeChildrenArray(NSNumber(value: 42)).isEmpty)
    #expect(AXHelpers.decodeChildrenArray(NSDictionary()).isEmpty)
}

/// A real CFArray of AXUIElements round-trips through the guarded decode.
@Test func testDecodeChildrenArrayDecodesRealCFArray() {
    let first = AXUIElementCreateApplication(4242)
    let second = AXUIElementCreateApplication(4243)
    let cfArray = [first, second] as CFArray

    let decoded = AXHelpers.decodeChildrenArray(cfArray as AnyObject)

    #expect(decoded.count == 2)
    #expect(CFEqual(decoded[0], first))
    #expect(CFEqual(decoded[1], second))
}

/// An empty CFArray decodes to an empty list (not nil, not a crash).
@Test func testDecodeChildrenArrayDecodesEmptyCFArray() {
    let cfArray = [AXUIElement]() as CFArray
    #expect(AXHelpers.decodeChildrenArray(cfArray as AnyObject).isEmpty)
}
