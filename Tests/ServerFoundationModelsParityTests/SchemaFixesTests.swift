// Regression tests for GenerationSchema fixes:
// - dependency definitions hoisted into $defs (no dangling $ref)
// - anyOf (union) dependency names are collected (no false undefinedReferences)
// - identical repeated definitions don't raise duplicateType; genuinely
//   conflicting ones still do
// - representNilExplicitlyInGeneratedContent renders nullable + required
// - GenerationGuide.pattern(String) renders the JSON Schema pattern keyword

import Foundation
import Testing
import ServerFoundationModels

@Suite("GenerationSchema fixes")
struct SchemaFixesTests {

    private func string() -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: String.self)
    }

    // MARK: $defs hoisting from dependencies

    @Test("A $ref into a dependency is hoisted into $defs")
    func dependencyReferenceResolvesInDocument() throws {
        let b = DynamicGenerationSchema(name: "B", properties: [
            .init(name: "value", schema: string())
        ])
        let root = DynamicGenerationSchema(name: "A", properties: [
            .init(name: "b", schema: DynamicGenerationSchema(referenceTo: "B"))
        ])
        let schema = try GenerationSchema(root: root, dependencies: [b])
        let document = schema.debugDescription
        #expect(document.contains("\"$defs\""))
        #expect(document.contains("\"B\""))
        #expect(document.contains("#/$defs/B"))
        // The hoisted definition carries B's actual shape, not a dangling ref.
        #expect(document.contains("\"value\""))
    }

    @Test("Dependencies referencing other dependencies are hoisted transitively")
    func transitiveDependencyReferencesResolve() throws {
        let c = DynamicGenerationSchema(name: "C", properties: [
            .init(name: "leaf", schema: string())
        ])
        let b = DynamicGenerationSchema(name: "B", properties: [
            .init(name: "c", schema: DynamicGenerationSchema(referenceTo: "C"))
        ])
        let root = DynamicGenerationSchema(name: "A", properties: [
            .init(name: "b", schema: DynamicGenerationSchema(referenceTo: "B"))
        ])
        let schema = try GenerationSchema(root: root, dependencies: [b, c])
        let document = schema.debugDescription
        #expect(document.contains("\"B\""))
        #expect(document.contains("\"C\""))
        #expect(document.contains("\"leaf\""))
    }

    // MARK: anyOf union names

    @Test("A reference to a union (anyOf) dependency does not throw undefinedReferences")
    func anyOfDependencyReferenceIsDefined() throws {
        let dog = DynamicGenerationSchema(name: "Dog", properties: [
            .init(name: "bark", schema: string())
        ])
        let cat = DynamicGenerationSchema(name: "Cat", properties: [
            .init(name: "meow", schema: string())
        ])
        let pet = DynamicGenerationSchema(name: "Pet", anyOf: [dog, cat])
        let root = DynamicGenerationSchema(name: "Owner", properties: [
            .init(name: "pet", schema: DynamicGenerationSchema(referenceTo: "Pet"))
        ])
        let schema = try GenerationSchema(root: root, dependencies: [pet])
        let document = schema.debugDescription
        #expect(document.contains("\"Pet\""))
        #expect(document.contains("anyOf"))
    }

    // MARK: duplicateType

    @Test("Embedding the same type twice does not throw duplicateType")
    func identicalRepeatedDefinitionsAllowed() throws {
        func address() -> DynamicGenerationSchema {
            DynamicGenerationSchema(name: "Address", properties: [
                .init(name: "city", schema: string())
            ])
        }
        let root = DynamicGenerationSchema(name: "Person", properties: [
            .init(name: "home", schema: address()),
            .init(name: "work", schema: address()),
        ])
        _ = try GenerationSchema(root: root, dependencies: [])
    }

    @Test("Conflicting definitions sharing a name still throw duplicateType")
    func conflictingDuplicateStillThrows() throws {
        let addressOne = DynamicGenerationSchema(name: "Address", properties: [
            .init(name: "city", schema: string())
        ])
        let addressTwo = DynamicGenerationSchema(name: "Address", properties: [
            .init(name: "zipCode", schema: string())
        ])
        let root = DynamicGenerationSchema(name: "Person", properties: [
            .init(name: "home", schema: addressOne),
            .init(name: "work", schema: addressTwo),
        ])
        do {
            _ = try GenerationSchema(root: root, dependencies: [])
            Issue.record("Expected duplicateType to be thrown")
        } catch let error as GenerationSchema.SchemaError {
            guard case .duplicateType(_, let type, _) = error else {
                Issue.record("Expected duplicateType, got \(error)")
                return
            }
            #expect(type == "Address")
        }
    }

    // MARK: representNilExplicitlyInGeneratedContent

    @Test("explicit nil: optional simple property becomes nullable and required")
    func explicitNilSimpleProperty() throws {
        let root = DynamicGenerationSchema(
            name: "Person",
            representNilExplicitlyInGeneratedContent: true,
            properties: [
                .init(name: "name", schema: string()),
                .init(name: "nickname", schema: string(), isOptional: true),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let document = schema.debugDescription
        #expect(document.contains(#"["string","null"]"#))
        #expect(document.contains(#""required":["name","nickname"]"#))
    }

    @Test("explicit nil: optional composite property becomes anyOf-with-null")
    func explicitNilCompositeProperty() throws {
        let address = DynamicGenerationSchema(name: "Address", properties: [
            .init(name: "city", schema: string())
        ])
        let root = DynamicGenerationSchema(
            name: "Person",
            representNilExplicitlyInGeneratedContent: true,
            properties: [
                .init(name: "address", schema: address, isOptional: true)
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let document = schema.debugDescription
        #expect(document.contains(#""anyOf""#))
        #expect(document.contains(#"{"type":"null"}"#))
        #expect(document.contains(#""required":["address"]"#))
    }

    @Test("without explicit nil, optional properties stay omitted from required")
    func defaultOptionalBehaviorUnchanged() throws {
        let root = DynamicGenerationSchema(
            name: "Person",
            representNilExplicitlyInGeneratedContent: false,
            properties: [
                .init(name: "name", schema: string()),
                .init(name: "nickname", schema: string(), isOptional: true),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let document = schema.debugDescription
        #expect(document.contains(#""required":["name"]"#))
        #expect(!document.contains("null"))
    }

    @Test("typed GenerationSchema init honors representNilExplicitlyInGeneratedContent")
    func explicitNilTypedInitializer() {
        let schema = GenerationSchema(
            type: String.self,
            representNilExplicitlyInGeneratedContent: true,
            properties: [
                .init(name: "nickname", type: String?.self)
            ]
        )
        let document = schema.debugDescription
        #expect(document.contains(#"["string","null"]"#))
        #expect(document.contains(#""required":["nickname"]"#))
    }

    // MARK: pattern guide

    @Test("GenerationGuide.pattern(String) renders the pattern keyword")
    func stringPatternGuideRenders() {
        let schema = GenerationSchema(
            type: String.self,
            properties: [
                .init(name: "year", type: String.self, guides: [.pattern("\\d{4}")])
            ]
        )
        let document = schema.debugDescription
        #expect(document.contains(#""pattern":"\\d{4}""#))
    }
}
