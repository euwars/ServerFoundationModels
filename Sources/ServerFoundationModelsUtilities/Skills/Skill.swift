// A skill: a named capability (instructions and/or tools, or a prompt payload)
// the model can activate on demand. Ported from apple/foundation-models-utilities,
// adapted to ServerFoundationModels.

import Foundation
import ServerFoundationModels

/// A capability that can be offered to a language model session, allowing the
/// model to activate specialized behavior on demand.
///
/// A skill pairs a name and description (visible to the model) with either a
/// `Prompt` or an instructions payload that takes effect when the model
/// activates it. In both cases the model activates a skill by generating a tool
/// call to the tool that ``Skills`` provides.
///
/// - Prompt-based skills add their content to the transcript as tool output —
///   this does not invalidate the prompt-prefix cache.
/// - Instructions-based skills insert their content into the instructions entry
///   at the top of the transcript (higher priority, but invalidates the cache).
public struct Skill {
    var name: String { storage.name }
    var description: String { storage.description }

    func activate() { storage.onActivate() }
    func deactivate() {
        if case .instructions(let skill) = storage {
            skill.onDeactivate()
        }
    }

    let storage: Storage

    enum Storage {
        case prompt(PromptSkill)
        case instructions(InstructionsSkill)

        var name: String {
            switch self {
            case .prompt(let skill): skill.name
            case .instructions(let skill): skill.name
            }
        }
        var description: String {
            switch self {
            case .prompt(let skill): skill.description
            case .instructions(let skill): skill.description
            }
        }
        var onActivate: @Sendable () -> Void {
            switch self {
            case .prompt(let skill): skill.onActivate
            case .instructions(let skill): skill.onActivate
            }
        }
    }

    // MARK: - Prompt-based

    public init(
        name: String,
        description: String,
        prompt: String,
        onActivate: @Sendable @escaping () -> Void = {}
    ) {
        self.init(name: name, description: description, onActivate: onActivate) {
            Prompt { prompt }
        }
    }

    public init(
        name: String,
        description: String,
        onActivate: @Sendable @escaping () -> Void = {},
        @PromptBuilder prompt: () -> Prompt
    ) {
        storage = .prompt(
            PromptSkill(name: name, description: description, prompt: prompt(), onActivate: onActivate)
        )
    }

    // MARK: - Instructions-based

    public init(
        name: String,
        description: String,
        instructions: some InstructionsRepresentable,
        allowsDeactivation: Bool = false,
        onActivate: @Sendable @escaping () -> Void = {},
        onDeactivate: @Sendable @escaping () -> Void = {}
    ) {
        storage = .instructions(
            InstructionsSkill(
                name: name,
                description: description,
                instructions: AnyDynamicInstructions(Instructions(instructions)),
                allowsDeactivation: allowsDeactivation,
                onActivate: onActivate,
                onDeactivate: onDeactivate
            )
        )
    }

    public init(
        name: String,
        description: String,
        allowsDeactivation: Bool = false,
        onActivate: @Sendable @escaping () -> Void = {},
        onDeactivate: @Sendable @escaping () -> Void = {},
        @DynamicInstructionsBuilder instructions: () -> some DynamicInstructions
    ) {
        storage = .instructions(
            InstructionsSkill(
                name: name,
                description: description,
                instructions: AnyDynamicInstructions(instructions()),
                allowsDeactivation: allowsDeactivation,
                onActivate: onActivate,
                onDeactivate: onDeactivate
            )
        )
    }
}

struct InstructionsSkill {
    let name: String
    let description: String
    let instructions: AnyDynamicInstructions
    let allowsDeactivation: Bool
    let onActivate: @Sendable () -> Void
    let onDeactivate: @Sendable () -> Void
}

struct PromptSkill {
    let name: String
    let description: String
    let prompt: Prompt
    let onActivate: @Sendable () -> Void
}
