// Robustness proofs for the JSON layer against untrusted model output:
// integer/decimal overflow traps, unbounded recursion (stack-exhaustion DoS),
// surrogate-pair corruption, and non-finite double serialization. All
// offline — no model server required.

import Foundation
import Testing
@testable import ServerFoundationModels

@Suite("JSON robustness")
struct JSONRobustnessTests {

    // MARK: - Integer overflow (no traps on untrusted numbers)

    @Test("decoding 1e20 as Int throws instead of trapping")
    func intFromHugeExponentThrows() throws {
        let content = try GeneratedContent(json: "1e20")
        #expect(throws: GeneratedContentError.self) {
            _ = try content.value(Int.self)
        }
    }

    @Test("decoding 100000000000000000000 as Int throws instead of trapping")
    func intFromHugeLiteralThrows() throws {
        let content = try GeneratedContent(json: "100000000000000000000")
        #expect(throws: GeneratedContentError.self) {
            _ = try content.value(Int.self)
        }
    }

    @Test("decoding 1e999 (infinity) as Int throws instead of trapping")
    func intFromInfinityThrows() throws {
        let content = try GeneratedContent(json: "1e999")
        #expect(throws: GeneratedContentError.self) {
            _ = try content.value(Int.self)
        }
    }

    @Test("in-range integral doubles still decode as Int")
    func intFromIntegralDoubleStillWorks() throws {
        let content = try GeneratedContent(json: "42.0")
        #expect(try content.value(Int.self) == 42)
    }

    @Test("non-integral doubles still throw for Int")
    func intFromFractionalDoubleThrows() throws {
        let content = try GeneratedContent(json: "1.5")
        #expect(throws: GeneratedContentError.self) {
            _ = try content.value(Int.self)
        }
    }

    // MARK: - Decimal overflow

    @Test("decoding 1e999 (infinity) as Decimal throws instead of trapping")
    func decimalFromInfinityThrows() throws {
        let content = try GeneratedContent(json: "1e999")
        #expect(throws: GeneratedContentError.self) {
            _ = try content.value(Decimal.self)
        }
    }

    @Test("finite values still decode as Decimal")
    func decimalFromFiniteStillWorks() throws {
        let content = try GeneratedContent(json: "3.5")
        #expect(try content.value(Decimal.self) == Decimal(3.5))
    }

    // MARK: - Nesting depth (stack-exhaustion DoS)

    @Test("100k nested arrays throws a depth error promptly in the strict parser")
    func deepNestingStrictThrows() {
        let pathological = String(repeating: "[", count: 100_000)
        #expect(throws: (any Error).self) {
            _ = try GeneratedContent(json: pathological)
        }
    }

    @Test("100k nested arrays (closed) throws a depth error, not stack overflow")
    func deepNestingClosedThrows() {
        let pathological = String(repeating: "[", count: 100_000)
            + String(repeating: "]", count: 100_000)
        #expect(throws: (any Error).self) {
            _ = try GeneratedContent(json: pathological)
        }
    }

    @Test("depth error mentions nesting depth")
    func depthErrorIsTyped() {
        let pathological = String(repeating: "[", count: 100_000)
        do {
            _ = try GeneratedContent(json: pathological)
            Issue.record("expected a parse error")
        } catch {
            #expect(String(describing: error).contains("nesting depth"))
        }
    }

    @Test("lenient partial parsing survives 100k nested arrays without crashing")
    func deepNestingLenientDoesNotCrash() {
        let pathological = String(repeating: "[", count: 100_000)
        // The lenient path returns nil rather than throwing; the requirement
        // is that it goes through the same guarded parser and never overflows
        // the stack.
        #expect(GeneratedContent.partial(json: pathological) == nil)
    }

    @Test("reasonable nesting still parses")
    func moderateNestingStillParses() throws {
        let json = String(repeating: "[", count: 100) + "1"
            + String(repeating: "]", count: 100)
        _ = try GeneratedContent(json: json)
    }

    // MARK: - Surrogate pairs

    @Test("valid surrogate pair decodes to the right scalar")
    func validSurrogatePairDecodes() throws {
        let content = try GeneratedContent(json: "\"\\uD83D\\uDE00\"")
        #expect(try content.value(String.self) == "😀")
    }

    @Test("high surrogate followed by a non-surrogate escape throws")
    func highSurrogateWithBadLowThrows() {
        #expect(throws: (any Error).self) {
            _ = try GeneratedContent(json: "\"\\uD800\\u0041\"")
        }
    }

    @Test("lone high surrogate throws")
    func loneHighSurrogateThrows() {
        #expect(throws: (any Error).self) {
            _ = try GeneratedContent(json: "\"\\uD800\"")
        }
    }

    @Test("lone high surrogate followed by literal text throws")
    func loneHighSurrogateBeforeLiteralThrows() {
        #expect(throws: (any Error).self) {
            _ = try GeneratedContent(json: "\"\\uD800A\"")
        }
    }

    @Test("lone low surrogate throws")
    func loneLowSurrogateThrows() {
        #expect(throws: (any Error).self) {
            _ = try GeneratedContent(json: "\"\\uDC00\"")
        }
    }

    @Test("ordinary unicode escapes still decode")
    func plainUnicodeEscapeStillWorks() throws {
        let content = try GeneratedContent(json: "\"\\u0041\\u00e9\"")
        #expect(try content.value(String.self) == "Aé")
    }

    // MARK: - Non-finite double serialization

    @Test("NaN serializes as valid JSON (null)")
    func nanSerializesAsNull() throws {
        let json = Double.nan.generatedContent.jsonString
        #expect(json == "null")
        _ = try GeneratedContent(json: json) // must be parseable
    }

    @Test("infinity serializes as valid JSON (null)")
    func infinitySerializesAsNull() throws {
        let json = Double.infinity.generatedContent.jsonString
        #expect(json == "null")
        _ = try GeneratedContent(json: json)
    }

    @Test("negative infinity serializes as valid JSON (null)")
    func negativeInfinitySerializesAsNull() throws {
        let json = (-Double.infinity).generatedContent.jsonString
        #expect(json == "null")
        _ = try GeneratedContent(json: json)
    }

    @Test("non-finite doubles nested in objects still produce parseable JSON")
    func nanInsideObjectIsParseable() throws {
        let content = GeneratedContent(properties: ["x": Double.nan, "y": 1.5])
        let json = content.jsonString
        #expect(json.contains("null"))
        let reparsed = try GeneratedContent(json: json)
        #expect(try reparsed.value(Double.self, forProperty: "y") == 1.5)
    }

    @Test("finite doubles keep their existing serialized format")
    func finiteDoubleFormatUnchanged() {
        #expect(JSONNode.number(1.0).serialized == "1.0")
        #expect(JSONNode.number(2.5).serialized == "2.5")
    }

    // MARK: - Round trip sanity

    @Test("normal object round-trips through serialize/parse")
    func normalRoundTrip() throws {
        let original = GeneratedContent(properties: [
            "name": "Ada",
            "age": 36,
            "height": 1.65,
            "admin": true,
            "nickname": Optional<String>.none,
            "tags": ["math", "computing"],
        ])
        let reparsed = try GeneratedContent(json: original.jsonString)
        #expect(try reparsed.value(String.self, forProperty: "name") == "Ada")
        #expect(try reparsed.value(Int.self, forProperty: "age") == 36)
        #expect(try reparsed.value(Double.self, forProperty: "height") == 1.65)
        #expect(try reparsed.value(Bool.self, forProperty: "admin") == true)
        #expect(try reparsed.value(String?.self, forProperty: "nickname") == nil)
        #expect(try reparsed.value([String].self, forProperty: "tags") == ["math", "computing"])
        #expect(reparsed == original)
    }
}
