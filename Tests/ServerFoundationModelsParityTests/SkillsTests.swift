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

    @Test func nonDeactivatableSkillStaysActiveOnSecondToggle() async throws {
        let activations = SkillActivations()
        let skills = Skills(activations: activations) {
            Skill(name: "style", description: "style", instructions: "Be terse.", allowsDeactivation: false)
        }
        let toggle = try #require(AnyDynamicInstructions(skills).allInstructionTools.first)

        _ = try await toggle.call(GeneratedContent(properties: ["skill": "style"]))
        #expect(activations.contains("style"))
        let second = try await toggle.call(GeneratedContent(properties: ["skill": "style"]))
        #expect(activations.contains("style"))
        #expect(second.contains("cannot be deactivated"))
    }

    @Test func unknownSkillReturnsExplanatoryOutput() async throws {
        let skills = Skills(activations: SkillActivations()) {
            Skill(name: "known", description: "known") { "hi" }
        }
        let toggle = try #require(AnyDynamicInstructions(skills).allInstructionTools.first)
        let out = try await toggle.call(GeneratedContent(properties: ["skill": "missing"]))
        #expect(out.contains("missing"))
        #expect(out.contains("known"))
    }

    @Test func concurrentActivationAndIterationDoesNotCrash() async {
        let activations = SkillActivations()
        let names = (0..<8).map { "skill-\($0)" }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    for name in names {
                        activations.activate(name)
                        activations.deactivate(name)
                    }
                }
            }
            group.addTask {
                for _ in 0..<64 {
                    _ = Array(activations)
                    _ = activations.snapshot()
                }
            }
            await group.waitForAll()
        }
    }

    @Test func emptySkillsListProducesNoToggleTool() {
        let skills = Skills(activations: SkillActivations(), skills: [])
        #expect(AnyDynamicInstructions(skills).allInstructionTools.isEmpty)
    }

    @Test func renderedInstructionsHaveOneBlankLineBetweenSkills() {
        let skills = Skills(activations: SkillActivations()) {
            Skill(name: "alpha", description: "first") { "Alpha body." }
            Skill(name: "beta", description: "second") { "Beta body." }
        }
        let rendered = AnyDynamicInstructions(skills).allInstructionTexts.joined(separator: "\n")
        #expect(!rendered.contains("\n\n\n"))
        #expect(rendered.contains("first\n\nSkill: beta"))
    }
}
