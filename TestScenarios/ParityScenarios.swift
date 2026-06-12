// ParityScenarios.swift
//
// This SINGLE source file is compiled into TWO test targets (via symlink):
//
//   Tests/AppleFoundationModelsParityTests  → `import FoundationModels`
//       runs against Apple's local on-device model (SystemLanguageModel.default)
//
//   Tests/ServerFoundationModelsParityTests   → `import ServerFoundationModels`
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

#if PARITY_SUBJECT_IS_SERVER_FOUNDATION_MODELS
import ServerFoundationModels
#elseif canImport(FoundationModels)
import FoundationModels
#endif

#if PARITY_SUBJECT_IS_SERVER_FOUNDATION_MODELS || canImport(FoundationModels)

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

    @Test(
        "concurrent sessions stress (production trigger for transport races)",
        .enabled(if: ProcessInfo.processInfo.environment["PARITY_STRESS"] != nil, "set PARITY_STRESS=1")
    )
    func concurrentSessionsStress() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let session = LanguageModelSession(model: ParityModel.make())
                    for round in 0..<2 {
                        let response = try await session.respond(
                            to: "Reply with the single word: ok (worker \(worker), round \(round))",
                            options: GenerationOptions(temperature: 0, maximumResponseTokens: 512)
                        )
                        #expect(!response.content.isEmpty)
                    }
                }
            }
            try await group.waitForAll()
        }
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

    @Test("unbounded arrays generate sensible counts without fabricated padding")
    func unboundedArrayGeneration() async throws {
        // AnyLanguageModel #160: unguided array schemas forced a fixed item
        // count, fabricating entries until the token budget blew up.
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "List exactly three short activities for a rainy day.",
            generating: ActivityList.self,
            options: deterministic
        )
        #expect(!response.content.items.isEmpty)
        #expect(response.content.items.count <= 10)
        #expect(response.content.items.allSatisfy { !$0.name.isEmpty })
    }

    @Test("@Generable enum properties decode correctly without any @Guide annotations")
    func unguidedEnumProperty() async throws {
        // AnyLanguageModel #146: an enum stored property without @Guide
        // silently produced placeholder values for every member.
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Suggest a craft idea about shaping a clay bowl.",
            generating: PlainCraftIdea.self,
            options: deterministic
        )
        #expect(!response.content.title.isEmpty)
        #expect([CraftCategory.origami, .knitting, .pottery].contains(response.content.category))
    }

    @Test("single-property wrapper types decode real values, not placeholders")
    func wrapperTypeDecoding() async throws {
        // AnyLanguageModel #94: nested Generable wrapper types came back as
        // placeholder values from the system model backend.
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "List two short activities for a sunny day.",
            generating: ActivityList.self,
            options: deterministic
        )
        let names = response.content.items.map(\.name)
        #expect(!names.isEmpty)
        #expect(Set(names).count == names.count, "items should be distinct, not repeated placeholders")
        #expect(names.allSatisfy { $0.localizedCaseInsensitiveContains("placeholder") == false })
    }

    @Test("the transcript is observable while a stream is still being consumed")
    func transcriptObservableDuringStreaming() async throws {
        // AnyLanguageModel #103: the session transcript was not readable
        // until streaming finished.
        let session = LanguageModelSession(model: ParityModel.make())
        let stream = session.streamResponse(
            to: "Count from one to ten in English words.",
            options: deterministic
        )

        var sawPromptMidStream = false
        for try await _ in stream {
            if !sawPromptMidStream {
                sawPromptMidStream = session.transcript.contains { entry in
                    if case .prompt = entry { return true }
                    return false
                }
            }
        }
        #expect(sawPromptMidStream, "the prompt entry should be visible during streaming")
    }

    @Test("typed streaming yields PartiallyGenerated snapshots settling into the complete value")
    func typedStreamingPartials() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let stream = session.streamResponse(
            to: "Suggest a craft idea about folding a paper crane.",
            generating: CraftIdea.self,
            options: deterministic
        )

        var snapshots = 0
        var last: CraftIdea.PartiallyGenerated?
        for try await snapshot in stream {
            snapshots += 1
            last = snapshot.content
        }
        #expect(snapshots >= 1)
        let final = try #require(last)
        #expect(final.title?.isEmpty == false)
        #expect(final.category != nil)
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

    @Test("responses report token usage for input and output")
    func tokenUsageReported() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Reply with one short sentence about otters.",
            options: deterministic
        )
        #expect(response.usage.input.totalTokenCount > 0)
        #expect(response.usage.output.totalTokenCount > 0)
    }

    @Test("history transforms shape exactly what the model sees")
    func historyTransformInjection() async throws {
        // The transform injects a fact that exists nowhere else; the model can
        // only answer correctly if the transformed history reached it.
        let session = LanguageModelSession(profile: ParityInjectionProfile())
        let response = try await session.respond(
            to: "What is the user's favorite animal? Answer with just the animal name.",
            options: deterministic
        )
        #expect(response.content.localizedCaseInsensitiveContains("capybara"))
    }

    @Test("reasoning ('thinking') output is recorded as reasoning entries, never leaked into content")
    func reasoningRecordedSeparately() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Which weighs more, a kilogram of feathers or a kilogram of iron? One short sentence.",
            options: deterministic
        )
        #expect(!response.content.isEmpty)
        // Models that think (e.g. qwen via the chat-completions backend)
        // produce reasoning entries; models that don't produce none. Either
        // way reasoning never appears as response content.
        for entry in session.transcript {
            if case .reasoning(let reasoning) = entry {
                let reasoningText = plainText(reasoning.segments)
                #expect(!reasoningText.isEmpty)
                #expect(!response.content.contains(reasoningText))
            }
        }
        if case .response = session.transcript.last {} else {
            Issue.record("transcript should end with the response, after any reasoning entries")
        }
    }

    @Test(
        ".deep reasoningLevel reaches the backend (the on-device model rejects it)",
        .enabled(if: ParityModel.isOnDeviceBacked, "reasoning-capable backends accept .deep")
    )
    func deepReasoningLevel() async throws {
        // The on-device model does not support reasoning; the request must
        // surface that as an error rather than silently dropping the level.
        // (Reasoning-capable backends accept the same profile.)
        let session = LanguageModelSession(profile: ParityDeepProfile())
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(
                to: "What is 17 multiplied by 23? Reply with just the number.",
                options: deterministic
            )
        }
    }

    @Test("ResponseStream.collect() returns the completed response")
    func streamCollect() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.streamResponse(
            to: "Reply with one short sentence: what is the capital of Japan?",
            options: deterministic
        ).collect()
        #expect(response.content.localizedCaseInsensitiveContains("Tokyo"))
    }

    @Test("profile onPrompt/onResponse callbacks fire around each exchange")
    func profileLifecycleCallbacks() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(profile: ParityCallbackProfile(recorder: recorder))
        _ = try await session.respond(
            to: "Reply with the single word: ready",
            options: deterministic
        )
        #expect(recorder.calls.contains("prompt"))
        #expect(recorder.calls.contains("response"))
    }

    @Test("transcripts encode, decode, and expose post-instruction history")
    func transcriptCodableAndHistory() async throws {
        let session = LanguageModelSession(
            model: ParityModel.make(),
            instructions: "You are a terse assistant."
        )
        _ = try await session.respond(to: "What color is a ripe banana?", options: deterministic)

        let transcript = session.transcript
        #expect(!transcript.history.isEmpty)
        #expect(transcript.history.allSatisfy { entry in
            if case .instructions = entry { return false }
            return true
        })

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.count == transcript.count)
    }

    @Test("SystemLanguageModel reports model facts: context size, languages, token counts")
    func systemModelFacts() async throws {
        let model = SystemLanguageModel.default
        #expect(model.contextSize > 0)
        #expect(!model.supportedLanguages.isEmpty)
        #expect(model.supportsLocale(Locale(identifier: "en_US")))
        let tokens = try await model.tokenCount(for: "The quick brown fox jumps over the lazy dog.")
        #expect(tokens > 0)
    }

    @Test(
        "a use-case-configured SystemLanguageModel still responds",
        .enabled(if: ParityModel.isOnDeviceBacked, "SystemLanguageModel is Apple-OS-bound")
    )
    func useCaseConfiguredModel() async throws {
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: "Reply with the single word: ready",
            options: deterministic
        )
        #expect(!response.content.isEmpty)
    }

    @Test("a second request while one is in flight throws GenerationError.concurrentRequests")
    func concurrentRequestsThrow() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        async let first = session.respond(
            to: "Count from one to twenty in English words.",
            options: deterministic
        )
        try await Task.sleep(for: .milliseconds(150))

        // Apple rejects this with a "programmer error"; ServerFoundationModels with
        // GenerationError.concurrentRequests. Both must refuse the request.
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: "Quick: what is 1+1?", options: deterministic)
        }
        _ = try await first
    }

    @Test("session properties flow to tools via @SessionProperty during calls")
    func sessionPropertiesReachTools() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(
            model: ParityModel.make(),
            tools: [FavoriteColorTool(recorder: recorder)],
            instructions: "Use the favoriteColor tool to answer questions about the user's favorite color. Always call the tool."
        )

        #expect(session.properties.parityUserName == "anonymous")
        session.properties.parityUserName = "Farzad"

        let response = try await session.respond(
            to: "What is the user's favorite color? Use the favoriteColor tool.",
            options: deterministic
        )
        #expect(!response.content.isEmpty)
        #expect(recorder.calls == ["Farzad"])
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

    @Test("every scalar kind, optionals, and raw-value-less enums round-trip")
    func generableKitchenSinkRoundTrip() throws {
        _ = KitchenSink.generationSchema

        let record = KitchenSink(
            isActive: true,
            count: 7,
            ratio: 0.5,
            weight: 2.25,
            // Binary-exact so equality survives the JSON number round-trip
            // (19.99 would drift identically on Apple's implementation too).
            price: Decimal(string: "4.25")!,
            nickname: "sink",
            luckyNumber: nil,
            mood: .excited,
            pastMoods: [.neutral, .skeptical]
        )
        let restored = try KitchenSink(try GeneratedContent(json: record.generatedContent.jsonString))
        #expect(restored == record)

        // nil and non-nil optionals both survive the trip.
        var sparse = record
        sparse.nickname = nil
        sparse.luckyNumber = 42
        let sparseRestored = try KitchenSink(try GeneratedContent(json: sparse.generatedContent.jsonString))
        #expect(sparseRestored == sparse)

        // A raw-value-less enum decodes from its case name and rejects strangers.
        #expect(try ParityMood(GeneratedContent(json: "\"skeptical\"")) == .skeptical)
        #expect(throws: (any Error).self) {
            _ = try ParityMood(try GeneratedContent(json: "\"furious\""))
        }
    }

    @Test("an unresolvable schema reference throws SchemaError.undefinedReferences")
    func schemaErrorUndefinedReferences() throws {
        let dangling = DynamicGenerationSchema(
            name: "Wrapper",
            properties: [
                .init(name: "child", schema: DynamicGenerationSchema(referenceTo: "Nowhere"))
            ]
        )
        do {
            _ = try GenerationSchema(root: dangling, dependencies: [])
            Issue.record("expected SchemaError.undefinedReferences")
        } catch let error as GenerationSchema.SchemaError {
            if case .undefinedReferences(_, let references, _) = error {
                #expect(references.contains("Nowhere"))
            } else {
                Issue.record("expected .undefinedReferences, got \(error)")
            }
        }
    }

    @Test("invalid JSON throws GeneratedContent.ParsingError carrying the raw content")
    func parsingErrorCarriesRawContent() {
        do {
            _ = try GeneratedContent(json: "this is not json")
            Issue.record("expected ParsingError")
        } catch let error as GeneratedContent.ParsingError {
            #expect(error.rawContent == "this is not json")
        } catch {
            Issue.record("expected GeneratedContent.ParsingError, got \(error)")
        }
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

private func plainText(_ segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment in
        if case .text(let text) = segment { return text.content }
        return nil
    }.joined(separator: "\n")
}

// MARK: - Deterministic differential parity
//
// A scripted mock model drives BOTH libraries with identical executor event
// streams. Because the model is deterministic, every assertion here is
// EXACT — any divergence in session machinery (transcript building, tool
// loop, usage accounting, streaming) fails on one side.

@Suite("Deterministic differential parity")
struct DifferentialParityScenarios {

    @Test("a scripted text turn produces identical content, usage, and transcript shape")
    func scriptedTextTurn() async throws {
        let session = LanguageModelSession(model: ParityMockModel(events: [.text("Hello, world.")]))
        let response = try await session.respond(to: "hi")

        #expect(response.content == "Hello, world.")
        #expect(response.usage.input.totalTokenCount == 7)
        #expect(response.usage.output.totalTokenCount == 3)
        #expect(session.transcript.map(entryKind) == ["prompt", "response"])
    }

    @Test("a scripted tool loop produces the identical transcript sequence and final text")
    func scriptedToolLoop() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(
            model: ParityMockModel(events: [
                .toolCall(name: "echo", arguments: #"{"value": "ping"}"#),
                .text("done"),
            ]),
            tools: [EchoTool(recorder: recorder)],
            instructions: "Use tools."
        )
        let response = try await session.respond(to: "go")

        #expect(response.content == "done")
        #expect(recorder.calls == ["ping"])
        #expect(session.transcript.map(entryKind) == [
            "instructions", "prompt", "toolCalls", "toolOutput", "response",
        ])
    }

    @Test("abandoning a stream stops generation and settles the session")
    func streamAbandonmentCancels() async throws {
        let session = LanguageModelSession(
            model: ParityMockModel(events: [.slowFragments(["a", "b", "c", "d", "e", "f"])])
        )
        var sawSnapshot = false
        for try await _ in session.streamResponse(to: "hi") {
            sawSnapshot = true
            break  // abandon the stream mid-generation
        }
        #expect(sawSnapshot)
        try await Task.sleep(for: .seconds(2))
        #expect(session.isResponding == false, "generation must not keep running after the consumer leaves")
    }

    @Test("scripted streaming yields the identical cumulative snapshot sequence")
    func scriptedStreaming() async throws {
        let session = LanguageModelSession(
            model: ParityMockModel(events: [.fragments(["Hel", "lo"])])
        )
        var snapshots: [String] = []
        for try await snapshot in session.streamResponse(to: "hi") {
            snapshots.append(snapshot.content)
        }
        // Snapshot cadence is timing-dependent even on Apple's framework
        // (snapshots can observe later accumulation); the stable contract is
        // prefix-monotonic snapshots settling into the exact final text.
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { "Hello".hasPrefix($0) })
        #expect(snapshots.last == "Hello")
        #expect(session.transcript.map(entryKind) == ["prompt", "response"])
    }
}

private func entryKind(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions: return "instructions"
    case .prompt: return "prompt"
    case .toolCalls: return "toolCalls"
    case .toolOutput: return "toolOutput"
    case .response: return "response"
    case .reasoning: return "reasoning"
    @unknown default: return "unknown"
    }
}

struct ParityMockModel: LanguageModel {
    enum Event: Hashable {
        case text(String)
        case fragments([String])
        case slowFragments([String])
        case toolCall(name: String, arguments: String)
    }

    let events: [Event]

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling])
    }

    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(events: events)
    }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable {
            var events: [Event]
        }

        let configuration: Configuration

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ParityMockModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            // One scripted event per generation round, indexed by the number
            // of model-generated entries since the last prompt.
            var index = 0
            for entry in request.transcript {
                switch entry {
                case .prompt: index = 0
                case .toolCalls, .response, .reasoning: index += 1
                default: break
                }
            }
            switch configuration.events[min(index, configuration.events.count - 1)] {
            case .text(let text):
                await channel.send(.response(action: .appendText(text, tokenCount: 3)))
                await channel.send(.response(action: .updateUsage(
                    input: .init(totalTokenCount: 7, cachedTokenCount: 0),
                    output: .init(totalTokenCount: 3, reasoningTokenCount: 0)
                )))
            case .fragments(let fragments):
                for fragment in fragments {
                    await channel.send(.response(action: .appendText(fragment, tokenCount: 1)))
                }
            case .slowFragments(let fragments):
                for fragment in fragments {
                    await channel.send(.response(action: .appendText(fragment, tokenCount: 1)))
                    try await Task.sleep(for: .milliseconds(150))
                }
            case .toolCall(let name, let arguments):
                await channel.send(.toolCalls(action: .toolCall(
                    id: "call-1", name: name,
                    action: .appendArguments(arguments, tokenCount: 1)
                )))
            }
        }
    }
}

struct EchoTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let recorder: CallRecorder

    var name: String { "echo" }
    var description: String { "Echoes the value." }

    var parameters: GenerationSchema {
        try! GenerationSchema(
            root: DynamicGenerationSchema(name: "arguments", properties: [
                .init(name: "value", schema: DynamicGenerationSchema(type: String.self))
            ]),
            dependencies: []
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let value = (try? arguments.value(String.self, forProperty: "value")) ?? ""
        recorder.record(value)
        return "echoed \(value)"
    }
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
            .model(ParityModel.make())
            .temperature(0.0)
        } else {
            Profile {
                ParityInstructions(mode: mode)
            }
            .model(ParityModel.make())
            .historyTransform { entries in
                Array(entries.suffix(4))
            }
        }
    }
}

struct ParityInjectionProfile: LanguageModelSession.DynamicProfile {
    var body: some DynamicProfile {
        Profile {
            Instructions("You answer questions about the user using the conversation history.")
        }
        .model(ParityModel.make())
        .historyTransform { entries in
            let injected = Transcript.Entry.response(Transcript.Response(segments: [
                .text(Transcript.TextSegment(content: "Noted: the user's favorite animal is the capybara."))
            ]))
            // The transform sees the full request transcript; keep the
            // in-flight prompt terminal.
            if case .prompt = entries.last {
                return entries.dropLast() + [injected, entries.last!]
            }
            return entries + [injected]
        }
    }
}

struct ParityCallbackProfile: LanguageModelSession.DynamicProfile {
    let recorder: CallRecorder

    var body: some DynamicProfile {
        Profile {
            Instructions("You are a terse assistant.")
        }
        .model(ParityModel.make())
        .temperature(0.0)
        .onPrompt { _ in recorder.record("prompt") }
        .onResponse { _ in recorder.record("response") }
    }
}

struct ParityDeepProfile: LanguageModelSession.DynamicProfile {
    var body: some DynamicProfile {
        Profile {
            Instructions("You are a careful assistant. Answer tersely.")
        }
        .reasoningLevel(.deep)
        .temperature(0.0)
    }
}

@Generable(description: "A category of craft project")
enum CraftCategory: String {
    case origami = "origami project"
    case knitting = "knitting project"
    case pottery = "pottery project"
}

@Generable(description: "A list of activities")
struct ActivityList: Equatable {
    var items: [TravelActivity]
}

@Generable(description: "A craft project idea")
struct PlainCraftIdea: Equatable {
    var title: String
    var category: CraftCategory
}

@Generable(description: "A craft project idea")
struct CraftIdea: Equatable {
    @Guide(description: "Short title for the idea")
    var title: String
    @Guide(description: "The category that best fits the idea")
    var category: CraftCategory
}

@Generable(description: "How the assistant feels about an idea")
enum ParityMood {
    case excited
    case neutral
    case skeptical
}

@Generable(description: "A record exercising every scalar kind")
struct KitchenSink: Equatable {
    @Guide(description: "Whether the record is active")
    var isActive: Bool
    var count: Int
    var ratio: Double
    var weight: Float
    var price: Decimal
    var nickname: String?
    var luckyNumber: Int?
    var mood: ParityMood
    var pastMoods: [ParityMood]
}

@Generable(description: "A note about an attached image")
struct ImageNote {
    var image: ImageReference
    var note: String
}

extension SessionPropertyValues {
    @SessionPropertyEntry var parityUserName: String = "anonymous"
}

struct FavoriteColorTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let recorder: CallRecorder

    @SessionProperty(\.parityUserName) var userName

    var name: String { "favoriteColor" }
    var description: String { "Returns the favorite color of the current user." }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(name: "arguments", properties: [])
        return try! GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        recorder.record(userName)
        return "\(userName)'s favorite color is teal."
    }
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
