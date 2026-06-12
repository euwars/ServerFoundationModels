// ParityScenarios.swift
//
// This SINGLE source file is compiled into TWO test targets (via symlink):
//
//   Tests/AppleFoundationModelsParityTests  → `import FoundationModels`
//       runs against Apple's local on-device model (SystemLanguageModel.default)
//
//   Tests/LinuxFoundationParityTests   → `import LinuxFoundation`
//       runs against a local on-device model (ChatCompletionsLanguageModel → Ollama)
//
// Only the import — and which local model answers — differs. Every line of test
// code and every assertion is identical. The models are different, so scenarios
// assert behavioral contracts of the LIBRARY (API semantics, transcript shape,
// schema enforcement, tool-call loop, streaming behavior), never exact strings.
//
// Each target supplies its own `ParityModel` (ModelProvider.swift).

import Foundation
import Testing

#if PARITY_SUBJECT_IS_LINUX_FOUNDATION
import LinuxFoundation
#elseif canImport(FoundationModels)
import FoundationModels
#endif

#if PARITY_SUBJECT_IS_LINUX_FOUNDATION || canImport(FoundationModels)

private let deterministic = GenerationOptions(temperature: 0)

// MARK: - Behavior parity (requires a live local model)

@Suite(
    "Behavior parity (local model)",
    .serialized,
    .enabled(if: ParityModel.isAvailable, "local model is not available")
)
struct BehaviorParityScenarios {

    @Test("which model is under test")
    func modelUnderTest() {
        // Not an assertion — records which local model answered for this run.
        print("Parity model under test: \(ParityModel.displayName)")
    }

    @Test("respond(to:) returns non-empty content and records prompt + response in the transcript")
    func plainTextResponse() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Reply with one short sentence: what is the capital of France?",
            options: deterministic
        )

        #expect(!response.content.isEmpty)
        #expect(response.content.localizedCaseInsensitiveContains("Paris"))

        let entries = Array(session.transcript)
        #expect(entries.contains { if case .prompt = $0 { return true }; return false })
        #expect(entries.contains { if case .response = $0 { return true }; return false })
        if case .response = entries.last {} else {
            Issue.record("last transcript entry should be the response, got \(String(describing: entries.last))")
        }
    }

    @Test("instructions are honored and recorded as the first transcript entry")
    func instructionsInTranscript() async throws {
        let session = LanguageModelSession(
            model: ParityModel.make(),
            instructions: "You are a terse assistant. Answer with a single word when possible."
        )
        let response = try await session.respond(
            to: "What color is a ripe banana?",
            options: deterministic
        )

        #expect(!response.content.isEmpty)
        if case .instructions = session.transcript.first {} else {
            Issue.record("first transcript entry should be the instructions, got \(String(describing: session.transcript.first))")
        }
    }

    @Test("streamResponse(to:) yields cumulative snapshots that settle into the final content")
    func streamingSnapshotsAccumulate() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let stream = session.streamResponse(
            to: "Count from one to five in English words.",
            options: deterministic
        )

        var snapshots: [String] = []
        for try await snapshot in stream {
            snapshots.append(snapshot.content)
        }

        let final = try #require(snapshots.last)
        #expect(!final.isEmpty)
        // Snapshots are cumulative: each one extends the previous.
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.count <= $1.count })
        #expect(session.isResponding == false)

        let entries = Array(session.transcript)
        #expect(entries.contains { if case .response = $0 { return true }; return false })
    }

    @Test("respond(to:schema:) yields complete structured content matching a dynamic schema")
    func structuredOutputWithDynamicSchema() async throws {
        let root = DynamicGenerationSchema(
            name: "CityFact",
            properties: [
                .init(
                    name: "city",
                    description: "Name of the city",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "population",
                    description: "Approximate population as an integer",
                    schema: DynamicGenerationSchema(type: Int.self)
                ),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Give one fact about Tokyo.",
            schema: schema,
            options: deterministic
        )

        let city: String = try response.content.value(String.self, forProperty: "city")
        let population: Int = try response.content.value(Int.self, forProperty: "population")
        #expect(!city.isEmpty)
        #expect(population > 0)
        #expect(response.content.isComplete)
    }

    @Test("anyOf schema constrains the response to one of the allowed choices")
    func guidedAnyOfChoice() async throws {
        let schema = GenerationSchema(
            type: String.self,
            description: "The color of a clear daytime sky",
            anyOf: ["red", "blue", "green", "yellow"]
        )

        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "What is the color of a clear daytime sky?",
            schema: schema,
            options: deterministic
        )

        let value: String = try response.content.value(String.self)
        #expect(["red", "blue", "green", "yellow"].contains(value))
    }

    @Test("tool calls are executed and recorded as toolCalls + toolOutput transcript entries")
    func toolCalling() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(
            model: ParityModel.make(),
            tools: [ThermometerTool(recorder: recorder)],
            instructions: "Use the available tools to answer questions about temperature. Always call the tool rather than guessing."
        )
        let response = try await session.respond(
            to: "What is the current temperature in Tokyo? Use the currentTemperature tool.",
            options: deterministic
        )

        #expect(recorder.calls.count >= 1)
        #expect(!response.content.isEmpty)
        #expect(response.content.contains("18"))

        let entries = Array(session.transcript)
        #expect(entries.contains { if case .toolCalls = $0 { return true }; return false })
        #expect(entries.contains { if case .toolOutput = $0 { return true }; return false })
    }

    @Test("a new session resumed from a transcript retains conversation context")
    func transcriptContinuation() async throws {
        let first = LanguageModelSession(model: ParityModel.make())
        _ = try await first.respond(
            to: "My favorite animal is the otter. Acknowledge this in one short sentence.",
            options: deterministic
        )
        let priorCount = first.transcript.count

        let resumed = LanguageModelSession(model: ParityModel.make(), transcript: first.transcript)
        let response = try await resumed.respond(
            to: "What is my favorite animal? Answer with just the animal name.",
            options: deterministic
        )

        #expect(response.content.localizedCaseInsensitiveContains("otter"))
        #expect(resumed.transcript.count > priorCount)
    }

    @Test("prewarm is safe to call and the session still responds")
    func prewarmIsSafe() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        session.prewarm()
        let response = try await session.respond(
            to: "Reply with the single word: ready",
            options: deterministic
        )
        #expect(!response.content.isEmpty)
        #expect(session.isResponding == false)
    }

    @Test("respond(generating:) decodes @Generable types nested two array layers deep")
    func generableDeepNesting() async throws {
        // Regression target: arrays of structs containing arrays of structs.
        // Schema references ($ref without $defs) broke this in other
        // FoundationModels clones; schemas here must be fully inlined.
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Create a two-day travel plan for Tokyo with one or two activities per day.",
            generating: TravelPlan.self,
            options: deterministic
        )

        let plan = response.content
        #expect(!plan.city.isEmpty)
        #expect(!plan.days.isEmpty)
        #expect(plan.days.allSatisfy { !$0.activities.isEmpty })
        #expect(plan.days.flatMap(\.activities).allSatisfy { !$0.name.isEmpty })
    }

    @Test("respond(generating:) decodes a recursive @Generable type (object nesting its own type)")
    func generableRecursiveType() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Describe a tiny project folder: a root folder named src containing one subfolder named utils, which contains one file named helpers. Files have no children.",
            generating: FileNode.self,
            options: deterministic
        )

        let root = response.content
        #expect(!root.name.isEmpty)
        #expect(!root.children.isEmpty)
        // At least two levels of self-nesting decoded.
        #expect(root.children.contains { !$0.children.isEmpty })
    }

    @Test("@Guide anyOf constrains a generated @Generable property")
    func generableGuideAnyOf() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "What color is a clear daytime sky?",
            generating: SkyReport.self,
            options: deterministic
        )
        #expect(["red", "blue", "green", "yellow"].contains(response.content.color))
    }

    @Test("@Generable enum properties decode to a valid case")
    func generableEnumProperty() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Suggest a craft idea about folding a paper crane.",
            generating: CraftIdea.self,
            options: deterministic
        )
        #expect(!response.content.title.isEmpty)
        #expect(response.content.category == .origami)
    }

    @Test("a dynamic profile session responds and re-resolves the profile across mode switches")
    func dynamicProfileSession() async throws {
        // Mirrors the Origami sample's orchestrator: one session, a profile
        // that selects instructions/options per mode, switched mid-conversation.
        let mode = ParityModeBox()
        let session = LanguageModelSession(profile: ParityProfile(mode: mode))

        let first = try await session.respond(
            to: "What color is a ripe banana?",
            options: deterministic
        )
        #expect(!first.content.isEmpty)

        mode.value = "animals"
        let second = try await session.respond(
            to: "What animal says moo?",
            options: deterministic
        )
        #expect(!second.content.isEmpty)
        #expect(second.content.localizedCaseInsensitiveContains("cow"))
        #expect(session.transcript.count >= 4)
    }
}

// MARK: - API parity (no model required — pure library semantics)

@Suite("API parity — pure library semantics")
struct APIParityScenarios {

    @Test("GeneratedContent round-trips JSON and exposes typed property access")
    func generatedContentJSONRoundTrip() throws {
        let content = try GeneratedContent(
            json: #"{"name": "Ada", "age": 36, "tags": ["pioneer", "mathematician"]}"#
        )

        let name: String = try content.value(String.self, forProperty: "name")
        let age: Int = try content.value(Int.self, forProperty: "age")
        let tags: [String] = try content.value([String].self, forProperty: "tags")
        #expect(name == "Ada")
        #expect(age == 36)
        #expect(tags == ["pioneer", "mathematician"])

        #expect(throws: (any Error).self) {
            let _: String = try content.value(String.self, forProperty: "missing")
        }
    }

    @Test("GeneratedContent built from properties serializes to JSON and parses back")
    func generatedContentPropertiesToJSON() throws {
        let content = GeneratedContent(properties: [
            "city": "Lagos",
            "population": 15_000_000,
        ])
        let parsed = try GeneratedContent(json: content.jsonString)

        let city: String = try parsed.value(String.self, forProperty: "city")
        let population: Int = try parsed.value(Int.self, forProperty: "population")
        #expect(city == "Lagos")
        #expect(population == 15_000_000)
    }

    @Test("GenerationOptions is value-equatable")
    func generationOptionsEquality() {
        #expect(GenerationOptions(temperature: 0.5) == GenerationOptions(temperature: 0.5))
        #expect(GenerationOptions(temperature: 0.5) != GenerationOptions(temperature: 0.9))
        #expect(GenerationOptions() == GenerationOptions())
        #expect(GenerationOptions(maximumResponseTokens: 10) != GenerationOptions())
    }

    @Test("Prompt and Instructions result builders accept multi-line string content")
    func promptAndInstructionsBuilders() throws {
        let prompt = Prompt {
            "You are given a task."
            "Complete it carefully."
        }
        _ = prompt

        let instructions = Instructions {
            "Be helpful."
        }
        _ = instructions
    }

    @Test("@Generable enum values round-trip through their raw values")
    func generableEnumRoundTrip() throws {
        let restored = try CraftCategory(CraftCategory.origami.generatedContent)
        #expect(restored == .origami)
        #expect(throws: (any Error).self) {
            _ = try CraftCategory(try GeneratedContent(json: "\"basket weaving\""))
        }
    }

    @Test("ImageReference participates in @Generable schemas and round-trips")
    func imageReferenceSchema() throws {
        _ = ImageNote.generationSchema
        let reference = try ImageReference(GeneratedContent(json: #"{"attachmentLabel": "photo-1"}"#))
        let note = ImageNote(image: reference, note: "inspiration")
        let restored = try ImageNote(try GeneratedContent(json: note.generatedContent.jsonString))
        #expect(restored.image.attachmentLabel == "photo-1")
        #expect(restored.note == "inspiration")
    }

    @Test("recursive @Generable schema construction terminates and values round-trip")
    func generableRecursiveRoundTrip() throws {
        // Schema construction must not recurse forever on self-referential types.
        _ = FileNode.generationSchema

        let tree = FileNode(name: "src", children: [
            FileNode(name: "utils", children: [
                FileNode(name: "helpers", children: [])
            ]),
            FileNode(name: "main", children: []),
        ])
        let restored = try FileNode(try GeneratedContent(json: tree.generatedContent.jsonString))
        #expect(restored == tree)
    }

    @Test("@Generable values round-trip through GeneratedContent, two layers deep")
    func generableRoundTrip() throws {
        let plan = TravelPlan(
            city: "Lisbon",
            days: [
                TravelDay(dayNumber: 1, activities: [
                    TravelActivity(name: "Tram 28 ride", durationMinutes: 60),
                    TravelActivity(name: "Castle walk", durationMinutes: 120),
                ]),
                TravelDay(dayNumber: 2, activities: [
                    TravelActivity(name: "Tile museum", durationMinutes: 90)
                ]),
            ]
        )

        let restored = try TravelPlan(try GeneratedContent(json: plan.generatedContent.jsonString))
        #expect(restored == plan)
    }

    @Test("Transcript behaves as a RandomAccessCollection of entries")
    func transcriptCollectionSemantics() {
        let empty = Transcript()
        #expect(empty.isEmpty)

        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "hello"))]))
        ]
        let transcript = Transcript(entries: entries)
        #expect(transcript.count == 1)
        if case .prompt = transcript[transcript.startIndex] {} else {
            Issue.record("expected the first entry to be a prompt")
        }
    }
}

// MARK: - Shared @Generable fixtures

@Generable(description: "A short travel activity")
struct TravelActivity: Equatable {
    @Guide(description: "Short name of the activity")
    var name: String
    @Guide(description: "Duration in minutes", .range(15...240))
    var durationMinutes: Int
}

@Generable(description: "One day of a travel plan")
struct TravelDay: Equatable {
    @Guide(description: "Day number, starting at 1", .minimum(1))
    var dayNumber: Int
    @Guide(description: "Activities planned for this day", .minimumCount(1))
    var activities: [TravelActivity]
}

@Generable(description: "A complete travel plan for one city")
struct TravelPlan: Equatable {
    @Guide(description: "Name of the destination city")
    var city: String
    @Guide(description: "The days of the plan", .count(2))
    var days: [TravelDay]
}

@Generable(description: "A node in a file tree: a file or a folder")
struct FileNode: Equatable {
    @Guide(description: "Name of the file or folder")
    var name: String
    @Guide(description: "Child nodes; empty for plain files", .maximumCount(3))
    var children: [FileNode]
}

@Generable(description: "A report about the sky")
struct SkyReport: Equatable {
    @Guide(description: "The color of the sky", .anyOf(["red", "blue", "green", "yellow"]))
    var color: String
}

// MARK: - Shared dynamic-profile fixtures (Origami-shaped)

final class ParityModeBox: @unchecked Sendable {
    var value: String = "colors"
}

struct ParityInstructions: DynamicInstructions {
    let mode: ParityModeBox

    var body: some DynamicInstructions {
        Instructions("You are a terse assistant. Answer with a single word when possible.")
        if mode.value == "colors" {
            Instructions("You answer questions about colors.")
        } else {
            Instructions("You answer questions about animals.")
        }
    }
}

struct ParityProfile: LanguageModelSession.DynamicProfile {
    let mode: ParityModeBox

    var body: some DynamicProfile {
        if mode.value == "colors" {
            Profile {
                ParityInstructions(mode: mode)
            }
            .temperature(0.0)
        } else {
            Profile {
                ParityInstructions(mode: mode)
            }
            .model(SystemLanguageModel())
            .historyTransform { entries in
                Array(entries.suffix(4))
            }
        }
    }
}

@Generable(description: "A category of craft project")
enum CraftCategory: String {
    case origami = "origami project"
    case knitting = "knitting project"
    case pottery = "pottery project"
}

@Generable(description: "A craft project idea")
struct CraftIdea: Equatable {
    @Guide(description: "Short title for the idea")
    var title: String
    @Guide(description: "The category that best fits the idea")
    var category: CraftCategory
}

@Generable(description: "A note about an attached image")
struct ImageNote {
    var image: ImageReference
    var note: String
}

// MARK: - Shared test fixtures

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

struct ThermometerTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let recorder: CallRecorder

    var name: String { "currentTemperature" }
    var description: String { "Returns the current temperature in a city, in degrees celsius." }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "arguments",
            properties: [
                .init(
                    name: "city",
                    description: "Name of the city",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let city = (try? arguments.value(String.self, forProperty: "city")) ?? "unknown"
        recorder.record(city)
        return "The current temperature in \(city) is exactly 18 degrees celsius."
    }
}

#endif
