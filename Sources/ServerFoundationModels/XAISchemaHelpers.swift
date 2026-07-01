// xAI strict JSON schema requirements: additionalProperties: false on every
// object node and all declared properties listed in required.

import Foundation

enum XAISchemaHelpers {
    static func strictSchema(from schema: GenerationSchema) -> JSONNode {
        enforceXAIStrict(schema.jsonSchemaDocument)
    }

    static func enforceXAIStrict(_ node: JSONNode) -> JSONNode {
        switch node {
        case .array(let elements):
            return .array(elements.map(enforceXAIStrict))
        case .object(let members):
            var updated = members.map { member in
                JSONNode.Member(key: member.key, value: enforceXAIStrict(member.value))
            }
            let typeValue = updated.first { $0.key == "type" }?.value
            if case .string("object") = typeValue,
                let propertiesIndex = updated.firstIndex(where: { $0.key == "properties" }),
                case .object(let propertyMembers) = updated[propertiesIndex].value {
                let requiredKeys = propertyMembers.map(\.key).sorted()
                if let existingRequired = updated.firstIndex(where: { $0.key == "required" }) {
                    updated[existingRequired] = .init(
                        key: "required",
                        value: .array(requiredKeys.map { .string($0) })
                    )
                } else {
                    updated.append(.init(
                        key: "required",
                        value: .array(requiredKeys.map { .string($0) })
                    ))
                }
                if let additionalIndex = updated.firstIndex(where: { $0.key == "additionalProperties" }) {
                    updated[additionalIndex] = .init(key: "additionalProperties", value: .bool(false))
                } else {
                    updated.append(.init(key: "additionalProperties", value: .bool(false)))
                }
            }
            return .object(updated)
        default:
            return node
        }
    }
}