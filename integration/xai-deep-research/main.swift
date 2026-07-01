// Custom multi-agent deep research on xAI, end to end:
//
//   Plan ──▶ [Research × N] ──▶ [Verify × N (adversarial)] ──▶ Synthesize
//
// Research and Verify are pipelined per angle (no barrier between them); each
// agent is an independent LanguageModelSession sharing the pooled HTTP client.
// The effort profile is flipped per stage — wide+cheap to gather, deep+skeptical
// to trust, then synthesize only what survives.
//
// Usage:
//   XAI_API_KEY=... swift run XAIDeepResearchProbe "your research question"
// With no argument it uses a default question.
import Foundation
import ServerFoundationModels

@Generable
struct ResearchPlan {
    @Guide(.minimumCount(3))
    var angles: [String]
}

@Generable
struct Verdict {
    @Guide(description: "True only if the cited sources actually support the claim.")
    var supported: Bool
    @Guide(description: "Specific unsupported or contradicted points; empty if fully supported.")
    var issues: [String]
}

struct Finding: Sendable {
    let angle: String
    let summary: String
    let sources: [String]
    let researchTime: Duration
    let verifyTime: Duration
    let verdict: Verdict
}

func secs(_ d: Duration) -> String {
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.1fs", s)
}

// Top-level (nonisolated) so task-group children can spawn sessions off the main actor.
func makeSession(_ m: XAIModel, _ tools: Set<XAIServerTool> = [], _ instructions: String? = nil, key: String) -> LanguageModelSession {
    LanguageModelSession(
        model: XAILanguageModel(name: m, auth: .apiKey(key), serverTools: tools),
        instructions: instructions.map { Instructions($0) }
    )
}

@main
struct DeepResearchProbe {
    static let clock = ContinuousClock()

    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY"], !key.isEmpty else {
            print("RESULT: FAIL — XAI_API_KEY required"); exit(1)
        }
        let argument = CommandLine.arguments.dropFirst().joined(separator: " ")
        let question = argument.isEmpty
            ? "Compare the leading open-source LLM inference servers in 2026 "
                + "(vLLM, Hugging Face TGI, and llama.cpp): throughput/performance, key features, "
                + "and developer sentiment."
            : argument

        let wallStart = clock.now
        print("QUESTION: \(question)\n")

        // ---- Stage 1: Plan (deep, typed decomposition) ----
        let t1 = clock.now
        let plan = try await makeSession(.grok4_3, [], "Decompose research questions into distinct, search-ready angles.", key: key)
            .respond(
                to: "Break this into 3-4 distinct research angles (each a specific search query): \(question)",
                generating: ResearchPlan.self,
                contextOptions: ContextOptions(reasoningLevel: .deep)
            ).content
        let angles = Array(plan.angles.prefix(4))
        print("--- Stage 1: PLAN (\(secs(clock.now - t1))) ---")
        for (i, a) in angles.enumerated() { print("  [\(i)] \(a)") }
        print("")

        // ---- Stages 2+3: Research -> Verify, pipelined per angle ----
        print("--- Stages 2+3: RESEARCH + adversarial VERIFY (parallel) ---")
        let stageStart = clock.now
        let findings = await withTaskGroup(of: Finding?.self) { group in
            for angle in angles {
                group.addTask {
                    do {
                        // 2. Research: fast, wide, server-side search + citations.
                        let rStart = clock.now
                        let rs = makeSession(.grok4_1Fast, [.webSearch, .xSearch],
                                             "Research the question using web and X search. Answer concisely with citations.", key: key)
                        let r = try await rs.respond(to: angle, contextOptions: ContextOptions(reasoningLevel: .light))
                        let sources = XAIServerToolSegmentCollector.segments(in: rs.transcript).flatMap {
                            seg -> [String] in
                            switch seg.content {
                            case .webSearch(let w):
                                return (w.outcome?.citations ?? []).map(\.url.absoluteString)
                            case .xSearch(let x):
                                return (x.outcome?.citations ?? []).map(\.url.absoluteString)
                            default: return []
                            }
                        }
                        let researchTime = clock.now - rStart

                        // 3. Verify: deep, adversarial — re-check the sources, try to refute.
                        let vStart = clock.now
                        let vs = makeSession(.grok4_3, [.webSearch],
                                             "You are a skeptical fact-checker. Assume the claim is unsupported until sources prove it. Default supported=false when uncertain.", key: key)
                        let verdict = try await vs.respond(
                            to: "Claim: \(r.content)\nCited sources: \(sources.joined(separator: ", "))\n"
                                + "Verify each point against the sources and refute anything unsupported.",
                            generating: Verdict.self,
                            contextOptions: ContextOptions(reasoningLevel: .deep)
                        ).content
                        let verifyTime = clock.now - vStart

                        return Finding(angle: angle, summary: r.content, sources: sources,
                                       researchTime: researchTime, verifyTime: verifyTime, verdict: verdict)
                    } catch {
                        print("  ! angle failed: \(angle.prefix(40)) — \(error)")
                        return nil
                    }
                }
            }
            var out: [Finding] = []
            for await f in group { if let f { out.append(f) } }
            return out
        }
        let stageWall = clock.now - stageStart

        let sumResearch = findings.map(\.researchTime).reduce(.zero, +)
        let sumVerify = findings.map(\.verifyTime).reduce(.zero, +)
        for f in findings {
            let mark = f.verdict.supported ? "✓ KEPT" : "✗ DROPPED"
            print("  \(mark) [research \(secs(f.researchTime)), verify \(secs(f.verifyTime)), \(f.sources.count) sources] \(f.angle.prefix(60))")
            if !f.verdict.supported, let issue = f.verdict.issues.first { print("        reason: \(issue.prefix(100))") }
        }
        let survivors = findings.filter { $0.verdict.supported }
        print("  stage wall-clock \(secs(stageWall)) vs serial sum \(secs(sumResearch + sumVerify)) "
            + "(\(findings.count) angles, \(survivors.count) survived)\n")

        // ---- Stage 4: Synthesize survivors only ----
        let t4 = clock.now
        let brief = survivors.map {
            "## \($0.angle)\n\($0.summary)\nsources: \($0.sources.joined(separator: ", "))"
        }.joined(separator: "\n\n")
        let report = try await makeSession(.grok4_3, [], "Write a well-structured, cited report. Use only the provided findings.", key: key)
            .respond(
                to: "Write a report answering: \(question)\n\nVerified findings:\n\n\(brief)",
                contextOptions: ContextOptions(reasoningLevel: .deep)
            ).content
        print("--- Stage 4: SYNTHESIZE (\(secs(clock.now - t4))) ---")
        print(report.prefix(1200))
        print("")

        // ---- Timing summary ----
        let total = clock.now - wallStart
        print("========================================")
        print("TOTAL wall-clock: \(secs(total))")
        print("  agents run: 1 plan + \(findings.count) research + \(findings.count) verify + 1 synth")
        print("  research+verify: \(secs(stageWall)) parallel vs \(secs(sumResearch + sumVerify)) if serial")
        print("RESULT: PASS")
    }
}
