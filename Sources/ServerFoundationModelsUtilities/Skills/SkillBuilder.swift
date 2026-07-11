// Result builder for `Skills { ... }`. Ported from
// apple/foundation-models-utilities, adapted to ServerFoundationModels.

import ServerFoundationModels

@resultBuilder
public struct SkillsBuilder {
    public static func buildBlock(_ components: [Skill]...) -> [Skill] {
        components.flatMap { $0 }
    }
    public static func buildExpression(_ expression: Skill) -> [Skill] {
        [expression]
    }
    public static func buildExpression(_ expression: Skill?) -> [Skill] {
        expression.map { [$0] } ?? []
    }
    public static func buildEither(first component: [Skill]) -> [Skill] {
        component
    }
    public static func buildEither(second component: [Skill]) -> [Skill] {
        component
    }
    public static func buildArray(_ components: [[Skill]]) -> [Skill] {
        components.flatMap { $0 }
    }
}
