// Model-driven subagents on xAI: the parent model itself decides to spawn
// research subagents by calling a tool, once per sub-question. Each call runs a
// full, independent LanguageModelSession (its own web search + reasoning) and
// returns its findings; the parent then synthesizes. Contrast with
// XAIDeepResearchProbe, where *code* orchestrates the fan-out.
//
// Usage:
//   XAI_API_KEY=… swift run XAISubagentsProbe "your research question"
import Foundation
import ServerFoundationModels

final class SpawnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String] = []
    func record(_ task: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        tasks.append(task)
        return tasks.count
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return tasks.count }
}

/// A tool the parent model calls to spawn a research subagent. The parent
/// decides how many to spawn and what each one investigates.
struct SpawnResearchSubagent: Tool {
    let key: String
    let log: SpawnLog
    let name = "spawnResearchSubagent"
    let description = "Spawn a research subagent to investigate one specific sub-question using web search. "
        + "Returns its findings with sources. Call it several times to cover different angles."
    @Generable struct Arguments {
        @Guide(description: "A specific, self-contained research sub-question") var task: String
    }

    func call(arguments: Arguments) async throws -> String {
        let n = log.record(arguments.task)
        print("  [spawn #\(n)] \(arguments.task.prefix(72))")
        let sub = LanguageModelSession(
            model: XAILanguageModel(name: .grok4_1Fast, auth: .apiKey(key), serverTools: [.webSearch, .xSearch]),
            instructions: "Research the sub-question with web/X search. Answer in 2-3 sentences with source URLs."
        )
        let r = try await sub.respond(to: arguments.task, contextOptions: ContextOptions(reasoningLevel: .light))
        print("  [done  #\(n)] \(r.content.prefix(72))")
        return r.content
    }
}

@main
struct SubagentsProbe {
    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY"], !key.isEmpty else {
            print("RESULT: FAIL — XAI_API_KEY required"); exit(1)
        }
        let argument = CommandLine.arguments.dropFirst().joined(separator: " ")
        let question = argument.isEmpty
            ? "What are the biggest open problems in Swift concurrency as of 2026, and how are they being addressed?"
            : argument

        let log = SpawnLog()
        let lead = LanguageModelSession(
            model: XAILanguageModel(name: .grok4_3, auth: .apiKey(key)),
            tools: [SpawnResearchSubagent(key: key, log: log)],
            instructions: """
                You are a research lead. Break the user's question into 3-4 focused sub-questions and
                delegate EACH one to a research subagent by calling the spawnResearchSubagent tool.
                Do not answer from your own knowledge — rely on the subagents. Once you have their
                findings, synthesize a single well-organized answer that cites the sources they returned.
                """
        )

        print("QUESTION: \(question)\n--- lead model delegating to subagents ---")
        let clock = ContinuousClock(); let t0 = clock.now
        let reply = try await lead.respond(to: question)
        let elapsed = clock.now - t0

        var toolCalls: [String] = []
        for e in lead.transcript { if case .toolCalls(let tc) = e { for c in tc { toolCalls.append(c.toolName) } } }

        print("\n--- synthesis by the lead ---")
        print(reply.content.prefix(1000))
        print("\n========================================")
        print("subagents spawned by the model: \(log.count)")
        print("tool calls in transcript: \(toolCalls.count)")
        let sec = Double(elapsed.components.seconds)
        print("elapsed: \(String(format: "%.1fs", sec))")
        print(log.count >= 2 && !reply.content.isEmpty
            ? "RESULT: PASS — the model spawned \(log.count) subagents itself and synthesized their findings"
            : "RESULT: PARTIAL — spawned=\(log.count)")
    }
}
