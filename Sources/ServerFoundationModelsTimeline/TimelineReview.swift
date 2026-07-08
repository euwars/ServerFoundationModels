// TimelineReview — reads the same RequestTimeline recording as TimelineReport
// and mechanically surfaces where a run is losing time: idle gaps, a
// single-threaded front-load, gate contention, a straggler session, wasted
// dead-end tool calls, duplicate work, and cost signals. Each finding carries
// an estimated wall-time it could recover, and the list is ranked by it — so
// the top line is the highest-leverage thing to fix next. App-agnostic: it
// reads only the timeline, so any ServerFoundationModels app gets the review.

import Foundation
import ServerFoundationModels

public struct TimelineFinding: Sendable {
    /// Estimated wall-clock seconds this issue could recover — the ranking key.
    /// Zero for informational findings (cost/latency signals, not time saved).
    public let impactSeconds: Double
    public let title: String
    public let detail: String
}

public enum TimelineReview {
    private static func sec(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }

    /// Union of intervals, sorted and merged, so overlaps count once.
    private static func merge(_ intervals: [(s: Double, e: Double)]) -> [(s: Double, e: Double)] {
        let sorted = intervals.sorted { $0.s < $1.s }
        var out: [(s: Double, e: Double)] = []
        for iv in sorted {
            if var last = out.last, iv.s <= last.e {
                last.e = max(last.e, iv.e)
                out[out.count - 1] = last
            } else {
                out.append(iv)
            }
        }
        return out
    }

    private static func peakConcurrency(_ intervals: [(s: Double, e: Double)]) -> Int {
        var events: [(t: Double, d: Int)] = []
        for iv in intervals { events.append((iv.s, 1)); events.append((iv.e, -1)) }
        events.sort { $0.t == $1.t ? $0.d < $1.d : $0.t < $1.t }
        var cur = 0, peak = 0
        for e in events { cur += e.d; peak = max(peak, cur) }
        return peak
    }

    /// The ranked optimization findings for the current recording.
    public static func findings() async -> [TimelineFinding] {
        let (requests, tools, marks) = await RequestTimeline.shared.snapshot()
        return analyze(requests: requests, tools: tools, marks: marks)
    }

    /// The pure analysis — ranked findings from an explicit recording. Split
    /// out from `findings()` so it is testable without the process-global
    /// timeline (and reusable on a decoded, saved timeline).
    public static func analyze(
        requests: [ModelRequestTiming],
        tools: [ToolRunTiming],
        marks: [TimelineMark]
    ) -> [TimelineFinding] {
        guard !requests.isEmpty else { return [] }
        var out: [TimelineFinding] = []

        let reqIv = requests.map { (s: sec($0.start), e: sec($0.start) + sec($0.total)) }
        let toolIv = tools.map { (s: sec($0.start), e: sec($0.start) + sec($0.duration)) }
        let allIv = reqIv + toolIv
        let wallStart = allIv.map(\.s).min() ?? 0
        let wallEnd = allIv.map(\.e).max() ?? 0
        let wall = max(wallEnd - wallStart, 0.001)
        let peak = max(peakConcurrency(reqIv), 1)

        // Single-threaded front-load: serial time before parallel work starts.
        if let mark = marks.first(where: { $0.label.lowercased().contains("pillar") || $0.label.lowercased().contains("parallel") }) {
            let front = sec(mark.at) - wallStart
            if front > 5 {
                out.append(.init(
                    impactSeconds: front * 0.5,
                    title: "Single-threaded front-load",
                    detail: String(format: "The first %.0fs (%.0f%% of the run) ran before any parallel work began. Overlapping setup (plan, prewarm) with the first parallel tasks reclaims part of it.", front, 100 * front / wall)))
            }
        }

        // Idle gaps: stretches where neither a request nor a tool is in flight.
        let merged = merge(allIv)
        var idle = 0.0
        var gaps: [(Double, Double)] = []
        var prev = wallStart
        for iv in merged {
            if iv.s - prev > 0.5 { idle += iv.s - prev; gaps.append((prev, iv.s)) }
            prev = max(prev, iv.e)
        }
        if idle > 3 {
            let biggest = gaps.sorted { ($0.1 - $0.0) > ($1.1 - $1.0) }.prefix(3)
                .map { String(format: "%.0f–%.0fs", $0.0 - wallStart, $0.1 - wallStart) }
                .joined(separator: ", ")
            out.append(.init(
                impactSeconds: idle,
                title: "Idle gaps — nothing in flight",
                detail: String(format: "%.0fs total idle (%.0f%% of the run). Largest at %@ — a barrier or serialization is stalling the pipeline there.", idle, 100 * idle / wall, biggest)))
        }

        // Gate contention: requests queuing for a concurrency slot.
        let gateWaits = requests.map { sec($0.gateWait) }
        let medGate = median(gateWaits)
        if medGate > 0.75 {
            out.append(.init(
                impactSeconds: medGate * Double(requests.count) / Double(peak),
                title: "Gate-bound — requests queue for a slot",
                detail: String(format: "Peak %d concurrent; requests waited a median %.1fs (max %.1fs) for a gate slot. Raising the concurrency cap lets more run at once — if the provider tolerates it.", peak, medGate, gateWaits.max() ?? 0)))
        }

        // Straggler: the session whose last request gates the whole run.
        let bySession = Dictionary(grouping: requests) { $0.session.isEmpty ? $0.model : $0.session }
        if bySession.count > 1 {
            let ends = bySession.mapValues { g in g.map { sec($0.start) + sec($0.total) }.max() ?? 0 }
                .sorted { $0.value < $1.value }
            let med = ends[ends.count / 2].value
            if let last = ends.last, last.value - med > 10 {
                out.append(.init(
                    impactSeconds: last.value - med,
                    title: "Straggler session gates the run",
                    detail: String(format: "'%@' finished %.0fs after the median session — it is the critical path. Splitting or trimming its work shortens the whole run.", last.key, last.value - med)))
            }
        }

        // Wasted tool runs: dead ends, blocked hosts, exhausted budgets.
        let deadPatterns = ["blocks automated", "nothing relevant", "did not render", "budget is exhausted", "do not retry", "no readable text", "already refused", "http 4", "invalid arguments", "no tool named"]
        let wasted = tools.filter { t in let o = t.output.lowercased(); return deadPatterns.contains { o.contains($0) } }
        if !wasted.isEmpty {
            let secs = wasted.map { sec($0.duration) }.reduce(0, +)
            let byTool = Dictionary(grouping: wasted, by: \.tool).mapValues(\.count)
                .sorted { $0.value > $1.value }.map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
            out.append(.init(
                impactSeconds: secs / Double(peak),
                title: "Wasted tool runs (dead ends / blocked)",
                detail: String(format: "%d tool runs returned nothing usable (%@) — %.0fs of work. Steer the model off these paths (blocked hosts, dead URLs) before it tries them.", wasted.count, byTool, secs)))
        }

        // Duplicate tool calls: identical tool + input, repeated.
        var seen: [String: Int] = [:]
        for t in tools { seen[t.tool + "\u{0}" + t.input, default: 0] += 1 }
        let dupCount = seen.values.filter { $0 > 1 }.map { $0 - 1 }.reduce(0, +)
        if dupCount > 2 {
            out.append(.init(
                impactSeconds: 0,
                title: "Duplicate tool calls",
                detail: "\(dupCount) tool calls repeated an identical input — cache them or teach the model it already has the answer."))
        }

        // Time-to-first-token dominance (informational — points at the model).
        let shares = requests.compactMap { r -> Double? in let t = sec(r.total); return t > 0.5 ? sec(r.firstToken) / t : nil }
        let medShare = median(shares)
        if medShare > 0.45 {
            out.append(.init(
                impactSeconds: 0,
                title: "Time-to-first-token dominates turns",
                detail: String(format: "TTFT is a median %.0f%% of each turn — provider latency/reasoning, not generation, is the cost. A faster seat or lower reasoning would move the needle.", 100 * medShare)))
        }

        // Input-token bloat (informational — points at context growth).
        let tin = requests.map { $0.inputTokens }.reduce(0, +)
        let tout = requests.map { $0.outputTokens }.reduce(0, +)
        if tout > 0, Double(tin) / Double(tout) > 15 {
            out.append(.init(
                impactSeconds: 0,
                title: "Input tokens dwarf output",
                detail: "Input \(tin / 1000)k vs output \(tout / 1000)k (\(tin / max(tout, 1))×) — carried transcript or grounding drives the token bill. Denser context or shorter history would cut it."))
        }

        // Failed requests: wasted latency plus the retry that followed.
        let failed = requests.filter { !$0.succeeded }
        if !failed.isEmpty {
            out.append(.init(
                impactSeconds: failed.map { sec($0.total) }.reduce(0, +) / Double(peak),
                title: "Failed model requests",
                detail: "\(failed.count) requests failed — each is wasted latency plus the retry it triggered."))
        }

        return out.sorted { $0.impactSeconds > $1.impactSeconds }
    }

    /// A ranked, human-readable review — written next to the timeline per run.
    public static func markdown() async -> String {
        let (requests, tools, marks) = await RequestTimeline.shared.snapshot()
        guard !requests.isEmpty else { return "# Timeline review\n\nNo model requests recorded." }
        let reqIv = requests.map { (s: sec($0.start), e: sec($0.start) + sec($0.total)) }
        let allIv = reqIv + tools.map { (s: sec($0.start), e: sec($0.start) + sec($0.duration)) }
        let wall = (allIv.map(\.e).max() ?? 0) - (allIv.map(\.s).min() ?? 0)
        let items = analyze(requests: requests, tools: tools, marks: marks)
        var lines = [
            "# Timeline review",
            "",
            String(format: "%.0fs wall · %d requests · %d tool runs · peak %d concurrent.", wall, requests.count, tools.count, peakConcurrency(reqIv)),
            "",
        ]
        if items.isEmpty {
            lines.append("No material optimization opportunities found — the run is well-packed.")
            return lines.joined(separator: "\n")
        }
        lines.append("Ranked by estimated recoverable wall time:")
        lines.append("")
        for (i, item) in items.enumerated() {
            let tag = item.impactSeconds >= 1 ? String(format: " (~%.0fs)", item.impactSeconds) : ""
            lines.append("\(i + 1). **\(item.title)**\(tag) — \(item.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// The top findings as a compact console block for the end-of-run log.
    public static func summary(top: Int = 3) async -> String {
        let items = await findings()
        guard !items.isEmpty else { return "review: run is well-packed — no material gaps" }
        var lines = ["review — top optimization opportunities:"]
        for item in items.prefix(top) {
            let tag = item.impactSeconds >= 1 ? String(format: " (~%.0fs)", item.impactSeconds) : ""
            lines.append("  • \(item.title)\(tag)")
        }
        return lines.joined(separator: "\n")
    }
}
