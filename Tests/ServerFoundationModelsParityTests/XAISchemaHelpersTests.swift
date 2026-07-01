import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAISchemaHelpersTests {
    @Test func enforceStrictAddsRequiredAndAdditionalProperties() throws {
        let root = DynamicGenerationSchema(name: "Answer", properties: [
            .init(name: "title", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "score", schema: DynamicGenerationSchema(type: Int.self)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let strict = XAISchemaHelpers.strictSchema(from: schema)
        let wire = strict.serialized
        #expect(wire.contains("\"additionalProperties\":false"))
        #expect(wire.contains("\"required\""))
        #expect(wire.contains("\"title\""))
        #expect(wire.contains("\"score\""))
    }
}