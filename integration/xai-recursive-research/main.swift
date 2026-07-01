// Recursive, self-verifying multi-agent research on xAI — built to behave like a
// reliable orchestrator, not a naive recursion:
//
//   • Parallel fan-out: `delegate` takes a LIST of sub-questions and runs them
//     concurrently (withTaskGroup), so nothing stalls sequentially.
//   • Recursion with rails: interior nodes delegate further (up to maxDepth);
//     leaves search the web directly. A shared budget caps total agents and
//     guarantees termination; depth caps tree height.
//   • Fault isolation: every leg is try/catch with one retry — a failed or hung
//     subagent degrades to a note instead of crashing the tree.
//   • Verify at the leaves (where facts are made), recall-tuned and flag-don't-drop
//     so one false negative can't prune a whole subtree.
//   • Observable: a live indented tree log + a coverage report at the end.
//
// Usage:
//   XAI_API_KEY=… swift run XAIRecursiveResearchProbe "your question"
import Foundation
import ServerFoundationModels

// MARK: - Shared tree state (budget, counters, logging)

final class TreeContext: @unchecked Sendable {
    let key: String
    let maxDepth: Int
    private let lock = NSLock()
    private var budget: Int
    private(set) var spawned = 0
    private(set) var denied = 0
    private(set) var failed = 0
    private(set) var unverified = 0

    init(key: String, maxDepth: Int, budget: Int) {
        self.key = key
        self.maxDepth = maxDepth
        self.budget = budget
    }

    private(set) var round = 0

    /// Atomically claims one agent from the shared budget. Returns false when spent.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if budget > 0 { budget -= 1; spawned += 1; return true }
        denied += 1
        return false
    }
    func beginRound() -> Int { lock.lock(); defer { lock.unlock() }; round += 1; return round }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return budget }
    func noteFailed() { lock.lock(); failed += 1; lock.unlock() }
    func noteUnverified() { lock.lock(); unverified += 1; lock.unlock() }
    func log(_ depth: Int, _ msg: String) {
        print(String(repeating: "   ", count: max(0, depth)) + msg)
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "spawned=\(spawned) denied(budget)=\(denied) failed=\(failed) unverified=\(unverified)"
    }
}

@Generable
struct Verdict {
    @Guide(description: "False ONLY if a claim is clearly contradicted, fabricated, or logically impossible — never for missing detail, hedging, or plausible-but-unfamiliar facts.")
    var supported: Bool
    @Guide(description: "The specific contradicted/fabricated claims; empty if acceptable.")
    var issues: [String]
}

// MARK: - The delegate tool (parallel fan-out; the model calls it with a list)

struct Delegate: Tool {
    let ctx: TreeContext
    let depth: Int
    let name = "delegate"
    let description = "Delegate several focused, independent sub-questions to research subagents that run "
        + "IN PARALLEL and return findings. Call once with all sub-questions. Deeper subagents may delegate "
        + "again; leaf subagents search the web directly."
    @Generable struct Arguments {
        @Guide(description: "2-4 focused, independent sub-questions to research in parallel")
        var subQuestions: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        // Each top-level delegate call is a research round the lead can repeat.
        if depth == 0 {
            let r = ctx.beginRound()
            ctx.log(0, "═══ ROUND \(r) ═══")
        }
        let tasks = Array(arguments.subQuestions.prefix(4))
        let results = await withTaskGroup(of: (Int, String).self) { group in
            for (i, q) in tasks.enumerated() {
                group.addTask { (i, await research(q, depth: depth + 1, ctx: ctx)) }
            }
            var acc: [(Int, String)] = []
            for await r in group { acc.append(r) }
            return acc.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var out = zip(tasks, results)
            .map { "### \($0.0)\n\($0.1)" }
            .joined(separator: "\n\n")

        // Coverage checkpoint: let the lead reflect and decide whether to dig deeper.
        if depth == 0 {
            let left = ctx.remaining
            out += "\n\n[coverage checkpoint — \(left) research agents of budget remain. "
                + (left > 0
                    ? "If an important aspect is still missing, thin, or only ⚠️ UNVERIFIED, call `delegate` "
                        + "AGAIN with focused follow-up sub-questions. Otherwise synthesize now.]"
                    : "Budget is exhausted — synthesize now and note any gaps.]")
        }
        return out
    }
}

// MARK: - One research node (recursive unit)

func research(_ question: String, depth: Int, ctx: TreeContext) async -> String {
    guard ctx.claim() else {
        return "[not researched — agent budget exhausted: \(question.prefix(60))]"
    }
    ctx.log(depth, "▶ [d\(depth)] \(question.prefix(72))")

    // Delegate only if there's budget left to make children worthwhile; otherwise
    // research directly (a leaf) instead of becoming a dead-weight middle-man.
    let interior = depth < ctx.maxDepth && ctx.remaining >= 3
    let tools: [any Tool] = interior ? [Delegate(ctx: ctx, depth: depth)] : []

    func attempt() async throws -> String {
        let session = LanguageModelSession(
            model: XAILanguageModel(
                name: depth <= 1 ? .grok4_3 : .grok4_1Fast,       // cheaper as you go deeper
                auth: .apiKey(ctx.key),
                serverTools: interior ? [] : [.webSearch, .xSearch]  // leaves search; interiors delegate
            ),
            tools: tools,
            instructions: interior
                ? "Decompose this into 2-3 focused, independent sub-questions and call `delegate` ONCE with all "
                    + "of them (they research in parallel). Then synthesize their returned findings into a cited "
                    + "answer. Preserve any ⚠️ UNVERIFIED markers you receive."
                : "Research this directly with web/X search. Answer in 3-5 sentences, each with a source URL."
        )
        return try await session.respond(
            to: question,
            contextOptions: ContextOptions(reasoningLevel: interior ? .moderate : .light)
        ).content
    }

    // Fault isolation: one retry, then degrade gracefully — never crash the tree.
    var findings: String
    do {
        findings = try await attempt()
    } catch {
        do {
            findings = try await attempt()
        } catch {
            ctx.noteFailed()
            ctx.log(depth, "  ✗ [d\(depth)] failed: \(String(describing: error).prefix(60))")
            return "[subagent failed after retry: \(question.prefix(50))]"
        }
    }

    // Verify at the leaves (recall-tuned, flag-don't-drop). Separate from the spawn
    // budget — verification must always be affordable.
    if !interior {
        if let verdict = try? await verifyLeaf(findings, ctx: ctx), !verdict.supported {
            ctx.noteUnverified()
            ctx.log(depth, "  ⚠️ [d\(depth)] flagged unverified: \(verdict.issues.first?.prefix(50) ?? "")")
            return "⚠️ UNVERIFIED (\(verdict.issues.first ?? "unsupported")): \(findings)"
        }
    }
    ctx.log(depth, "  ✓ [d\(depth)] done")
    return findings
}

func verifyLeaf(_ findings: String, ctx: TreeContext) async throws -> Verdict {
    let v = LanguageModelSession(
        model: XAILanguageModel(name: .grok4_1Fast, auth: .apiKey(ctx.key)),
        instructions: "You are a careful fact-checker. Mark supported=false ONLY when a claim is clearly "
            + "self-contradictory, fabricated, or logically impossible. Do not penalize missing detail, "
            + "hedging, or unfamiliar-but-plausible facts."
    )
    return try await v.respond(
        to: "Assess these findings; refute only clear errors:\n\(findings)",
        generating: Verdict.self,
        contextOptions: ContextOptions(reasoningLevel: .moderate)
    ).content
}

// MARK: - Entry point

@main
struct RecursiveResearchProbe {
    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY"], !key.isEmpty else {
            print("RESULT: FAIL — XAI_API_KEY required"); exit(1)
        }
        let argument = CommandLine.arguments.dropFirst().joined(separator: " ")
        let question = argument.isEmpty
            ? "What are the leading approaches to reduce LLM inference cost in 2026?"
            : argument

        let ctx = TreeContext(key: key, maxDepth: 2, budget: 15)
        let lead = LanguageModelSession(
            model: XAILanguageModel(name: .grok4_3, auth: .apiKey(key)),
            tools: [Delegate(ctx: ctx, depth: 0)],
            instructions: """
                You are the research lead, working in iterative rounds. You share a TOTAL budget of ~15
                research agents across ALL rounds, so pace yourself — spend roughly half in round 1 and keep
                the rest to dig into whatever turns out weak. Rely only on returned findings.

                1. Round 1: call `delegate` with just 2 broad sub-questions.
                2. When findings return, REFLECT out loud: what is now well-covered, and what important aspect
                   is still missing, thin, contradictory, or only marked ⚠️ UNVERIFIED?
                3. If meaningful gaps remain and budget remains, call `delegate` AGAIN with follow-up
                   sub-questions that target ONLY those gaps — never re-cover what an earlier round already
                   found. Repeat this reflect-and-refine loop (up to ~3 rounds) until coverage is thorough.
                4. Then synthesize a well-structured, cited answer. Treat ⚠️ UNVERIFIED content cautiously,
                   and end with a one-line note of any remaining gaps.
                """
        )

        print("QUESTION: \(question)")
        print("bounds: maxDepth=\(ctx.maxDepth), budget=15\n--- recursion tree ---")
        let clock = ContinuousClock(); let t0 = clock.now
        let reply: String
        do {
            reply = try await lead.respond(to: question).content
        } catch {
            print("\nRESULT: FAIL — lead errored: \(error)"); exit(1)
        }
        let elapsed = clock.now - t0

        print("\n--- synthesis ---")
        print(reply.prefix(1400))
        print("\n========================================")
        print("TREE: \(ctx.summary)")
        print("elapsed: \(String(format: "%.1fs", Double(elapsed.components.seconds)))")
        print(ctx.spawned >= 4 && !reply.isEmpty
            ? "RESULT: PASS — recursive parallel research completed within budget, verified at the leaves"
            : "RESULT: PARTIAL — spawned=\(ctx.spawned)")
    }
}
