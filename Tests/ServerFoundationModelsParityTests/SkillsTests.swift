import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct SkillsTests {
    @Test func activationsTrackNamesAndDedupe() {
        let a = SkillActivations()
        a.activate("x"); a.activate("x"); a.activate("y")
        #expect(a.contains("x"))
        #expect(Array(a).sorted() == ["x", "y"])
        a.deactivate("x")
        #expect(!a.contains("x"))
        #expect(Array(a) == ["y"])
    }

    @Test func skillsGeneratesToggleToolOverSkillNames() async throws {
        let activations = SkillActivations()
        let skills = Skills(activations: activations) {
            Skill(name: "pirate", description: "pirate voice") { "Talk like a pirate." }
            Skill(name: "calendar", description: "calendar", instructions: "Be punctual.", allowsDeactivation: true)
        }
        let tools = AnyDynamicInstructions(skills).allInstructionTools
        #expect(tools.count == 1)
        let toggle = try #require(tools.first)
        // A deactivatable skill is present, so the tool toggles rather than only activates.
        #expect(toggle.name == "toggle_skill")

        // Activating a prompt-based skill delivers its prompt as the tool output.
        let out = try await toggle.call(GeneratedContent(properties: ["skill": "pirate"]))
        #expect(out.lowercased().contains("pirate"))
    }

    @Test func instructionsSkillTogglesActivationState() async throws {
        let activations = SkillActivations()
        let skills = Skills(activations: activations) {
            Skill(name: "calendar", description: "calendar", instructions: "Be punctual.", allowsDeactivation: true)
        }
        let toggle = try #require(AnyDynamicInstructions(skills).allInstructionTools.first)

        _ = try await toggle.call(GeneratedContent(properties: ["skill": "calendar"]))
        #expect(activations.contains("calendar"))          // first call activates
        _ = try await toggle.call(GeneratedContent(properties: ["skill": "calendar"]))
        #expect(!activations.contains("calendar"))         // second call toggles off
    }

    @Test func activateOnlyToolWhenNoDeactivation() async throws {
        let skills = Skills(activations: SkillActivations()) {
            Skill(name: "style", description: "style") { "Be terse." }
        }
        let toggle = try #require(AnyDynamicInstructions(skills).allInstructionTools.first)
        // No deactivatable skill → the tool is named activate_skill.
        #expect(toggle.name == "activate_skill")
    }

    @Test func unknownSkillThrows() async throws {
        let skills = Skills(activations: SkillActivations()) {
            Skill(name: "known", description: "known") { "hi" }
        }
        let toggle = try #require(AnyDynamicInstructions(skills).allInstructionTools.first)
        await #expect(throws: UnknownSkillError.self) {
            _ = try await toggle.call(GeneratedContent(properties: ["skill": "missing"]))
        }
    }
}
