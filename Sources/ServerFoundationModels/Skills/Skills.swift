// `Skills`: a DynamicInstructions component that lists skills to the model and
// exposes a tool the model calls to toggle them on/off. Ported from
// apple/foundation-models-utilities, adapted to ServerFoundationModels.

import Foundation

/// A dynamic instructions component that manages a collection of ``Skill``
/// values, exposing them to the model as a tool it can call to toggle
/// individual skills on and off.
///
/// `Skills` generates a tool (named `toggle_skill` or `activate_skill` by
/// default) whose schema lists the available skill names. When the model calls
/// the tool, the corresponding skill is activated or deactivated and its
/// instructions or prompt are injected into the session.
///
/// ```swift
/// let activations = SkillActivations()
/// let session = LanguageModelSession(profile: Profile {
///     Skills(activations: activations) {
///         Skill(name: "style-guide", description: "Applies the writing style guide") {
///             "# Style Guide\nKeep phrasing literal."
///         }
///         Skill(name: "research", description: "Web research") {
///             Instructions("Use web search to answer, then cite the source.")
///         }
///     }
/// })
/// ```
public struct Skills: DynamicInstructions {
    private let toolName: String?
    private let toolDescription: String?
    private let skills: [Skill]
    private let strictSchema: Bool
    private let activations: SkillActivations

    public init(
        activations: SkillActivations,
        toolName: String? = nil,
        toolDescription: String? = nil,
        strictSchema: Bool = false,
        @SkillsBuilder skills: () -> [Skill]
    ) {
        self.init(
            activations: activations,
            toolName: toolName,
            toolDescription: toolDescription,
            strictSchema: strictSchema,
            skills: skills()
        )
    }

    public init(
        activations: SkillActivations,
        toolName: String? = nil,
        toolDescription: String? = nil,
        strictSchema: Bool = false,
        skills: [Skill]
    ) {
        self.activations = activations
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.skills = skills
        self.strictSchema = strictSchema
    }

    public var body: some DynamicInstructions {
        DynamicInstructions.ForEach(Array(skills.enumerated()), id: \.element.name) { item in
            let prefix = item.offset > 0 ? "\n" : ""
            let skill = item.element
            if case .instructions(let stored) = skill.storage {
                if activations.contains(skill.name) {
                    Instructions { "\(prefix)Skill: \(skill.name) [active]\n" }
                    stored.instructions
                } else {
                    Instructions { "\(prefix)Skill: \(skill.name) [inactive]\nDescription: \(skill.description)" }
                }
            } else {
                Instructions { "\(prefix)Skill: \(skill.name) [on demand]\nDescription: \(skill.description)" }
            }
        }

        if !skills.isEmpty {
            ToggleSkillTool(
                name: toolName,
                description: toolDescription,
                skills: skills,
                activations: activations,
                strictSchema: strictSchema,
                onCall: { [activations] skill in
                    switch skill.storage {
                    case .prompt:
                        skill.activate()
                    case .instructions(let stored):
                        if activations.contains(skill.name) {
                            guard stored.allowsDeactivation else { return }
                            activations.deactivate(skill.name)
                            skill.deactivate()
                        } else {
                            activations.activate(skill.name)
                            skill.activate()
                        }
                    }
                }
            )
        }
    }
}

/// Error thrown when the model asks to toggle a skill that doesn't exist.
public struct UnknownSkillError: Error, CustomStringConvertible {
    public let requested: String
    public let available: [String]
    public var description: String {
        "Model attempted to toggle a skill named '\(requested)', but no matching "
            + "skill was found. Available skills: \(available.joined(separator: ", "))"
    }
}

private struct ToggleSkillTool: @unchecked Sendable, Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let onCall: @Sendable (Skill) -> Void
    let skills: [Skill]
    let activations: SkillActivations

    init(
        name: String?,
        description: String?,
        skills: [Skill],
        activations: SkillActivations,
        strictSchema: Bool,
        onCall: @Sendable @escaping (Skill) -> Void
    ) {
        let allowsDeactivation = skills.lazy.compactMap { skill -> InstructionsSkill? in
            if case .instructions(let stored) = skill.storage { return stored }
            return nil
        }.contains(where: \.allowsDeactivation)

        let ownSkillNames = Set(skills.map(\.name))
        let activeNames = Set(activations).intersection(ownSkillNames)
        var allowed = skills.map(\.name).filter { !activeNames.contains($0) }
        if !strictSchema || allowsDeactivation {
            allowed += activeNames
        }
        allowed.sort()

        let resolvedName = name ?? (allowsDeactivation ? "toggle_skill" : "activate_skill")

        let hasOnDemandSkill = skills.contains { skill in
            if case .prompt = skill.storage { return true }
            return false
        }
        let onDemandExplanation: String? = hasOnDemandSkill
            ? "Skills marked [on demand] aren't toggled on or off; calling this tool on one delivers its guidance once."
            : nil
        let defaultDescription = allowsDeactivation
            ? "Activate or deactivate a skill." + (onDemandExplanation.map { " \($0)" } ?? "")
            : "Activates a skill." + (onDemandExplanation.map { " \($0)" } ?? "")

        // A one-property object whose `skill` field is an enum of the allowed names.
        let skillPropertySchema = allowed.isEmpty
            ? DynamicGenerationSchema(type: String.self)
            : DynamicGenerationSchema(name: "skill", anyOf: allowed)
        let argumentsRoot = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "skill", schema: skillPropertySchema)
            ]
        )
        let parameters: GenerationSchema
        if let schema = try? GenerationSchema(root: argumentsRoot, dependencies: []) {
            parameters = schema
        } else {
            let fallbackRoot = DynamicGenerationSchema(
                name: "Arguments",
                properties: [
                    DynamicGenerationSchema.Property(
                        name: "skill",
                        schema: DynamicGenerationSchema(type: String.self)
                    )
                ]
            )
            parameters = GenerationSchema(node: fallbackRoot.node)
        }

        self.name = resolvedName
        self.description = description ?? defaultDescription
        self.onCall = onCall
        self.parameters = parameters
        self.skills = skills
        self.activations = activations
    }

    func call(arguments: GeneratedContent) async throws -> Prompt {
        let requested = try arguments.value(String.self, forProperty: "skill")
        guard let skill = skills.first(where: { $0.name == requested }) else {
            let error = UnknownSkillError(requested: requested, available: skills.map(\.name))
            return Prompt { error.description }
        }
        switch skill.storage {
        case .prompt(let promptSkill):
            onCall(skill)
            return promptSkill.prompt
        case .instructions(let stored):
            if activations.contains(skill.name) {
                if !stored.allowsDeactivation {
                    return Prompt { "Skill '\(skill.name)' is already active and cannot be deactivated." }
                }
                onCall(skill)
                return Prompt { "Successfully deactivated skill: \(skill.name)" }
            } else {
                onCall(skill)
                return Prompt { "Successfully activated skill: \(skill.name)" }
            }
        }
    }
}
