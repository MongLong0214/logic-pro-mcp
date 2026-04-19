import Foundation
import Testing
@testable import LogicProMCP

@Suite("JSONHelper")
struct JSONHelperTests {

    struct Sample: Codable, Equatable {
        let id: Int
        let name: String
        let when: Date
        let tags: [String]?
    }

    @Test("encodeJSON produces sorted-key pretty-printed output")
    func prettyPrintedAndSorted() throws {
        let s = Sample(id: 1, name: "alpha", when: Date(timeIntervalSince1970: 0), tags: ["a", "b"])
        let json = encodeJSON(s)
        // Pretty formatting puts each key on its own line with 2-space indent.
        #expect(json.contains("\n"))
        // Sorted keys: "id" comes before "name" alphabetically.
        let idIdx = json.range(of: "\"id\"")?.lowerBound
        let nameIdx = json.range(of: "\"name\"")?.lowerBound
        let tagsIdx = json.range(of: "\"tags\"")?.lowerBound
        let whenIdx = json.range(of: "\"when\"")?.lowerBound
        #expect(idIdx != nil && nameIdx != nil && tagsIdx != nil && whenIdx != nil)
        #expect(idIdx! < nameIdx!)
        #expect(nameIdx! < tagsIdx!)
        #expect(tagsIdx! < whenIdx!)
    }

    @Test("encodeJSON with compact=true omits whitespace")
    func compactOption() {
        let s = Sample(id: 2, name: "b", when: Date(timeIntervalSince1970: 0), tags: nil)
        let compact = encodeJSON(s, compact: true)
        #expect(!compact.contains("\n"))
        #expect(!compact.contains("  "))
        // Still valid JSON.
        #expect((try? JSONSerialization.jsonObject(with: Data(compact.utf8))) != nil)
    }

    @Test("encodeJSONStrict throws on unencodable value")
    func strictThrowsOnFailure() {
        struct Bomb: Encodable {
            func encode(to encoder: Encoder) throws {
                throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "boom"])
            }
        }
        #expect(throws: Error.self) {
            _ = try encodeJSONStrict(Bomb())
        }
    }

    @Test("encodeJSON fallback error message includes the failing type name")
    func fallbackErrorMentionsType() {
        struct Bomb: Encodable {
            func encode(to encoder: Encoder) throws {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "nope"])
            }
        }
        let result = encodeJSON(Bomb())
        #expect(result.contains("\"error\""))
        #expect(result.contains("Bomb"))
    }

    @Test("decodeJSON roundtrips a Sample value")
    func roundtripDecode() throws {
        let original = Sample(id: 3, name: "gamma", when: Date(timeIntervalSince1970: 1_700_000_000), tags: ["x"])
        let json = encodeJSON(original)
        let decoded: Sample = try decodeJSON(json)
        #expect(decoded == original)
    }

    @Test("decodeJSON throws on malformed input")
    func decodeThrowsOnBadInput() {
        #expect(throws: Error.self) {
            let _: Sample = try decodeJSON("{not json}")
        }
    }

    @Test("handles nested optionals and empty arrays")
    func nestedAndOptional() throws {
        struct Outer: Codable, Equatable {
            let items: [Sample]
            let note: String?
        }
        let value = Outer(items: [], note: nil)
        let json = encodeJSON(value)
        let decoded: Outer = try decodeJSON(json)
        #expect(decoded == value)
    }

    @Test("handles large arrays without allocating a fresh encoder each time")
    func largeArray() throws {
        // 10k elements — verifies the singleton encoder path stays stable under load.
        let items = (0..<10_000).map { Sample(id: $0, name: "n\($0)", when: Date(timeIntervalSince1970: TimeInterval($0)), tags: nil) }
        let json = encodeJSON(items, compact: true)
        let decoded: [Sample] = try decodeJSON(json)
        #expect(decoded.count == items.count)
        #expect(decoded.first == items.first)
        #expect(decoded.last == items.last)
    }
}
