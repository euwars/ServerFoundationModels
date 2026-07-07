// TimelineReport — turn RequestTimeline's recordings into artifacts any
// ServerFoundationModels app can ship: raw JSON, a self-contained interactive
// HTML debugger, and a compact console summary.

import Foundation
import ServerFoundationModels

public enum TimelineReport {
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Everything recorded so far, as the timeline JSON the viewer reads.
    public static func json() async throws -> Data {
        let (requests, toolRuns, marks) = await RequestTimeline.shared.snapshot()
        let payload: [String: Any] = [
            "requests": requests.map { [
                "model": $0.model, "session": $0.session,
                "start": seconds($0.start), "gateWait": seconds($0.gateWait),
                "connect": seconds($0.connect), "firstToken": seconds($0.firstToken),
                "total": seconds($0.total), "ok": $0.succeeded,
                "prompt": $0.promptExcerpt, "response": $0.responseExcerpt,
                "tokensIn": $0.inputTokens, "tokensOut": $0.outputTokens,
            ] },
            "tools": toolRuns.map { [
                "tool": $0.tool, "session": $0.session,
                "start": seconds($0.start), "duration": seconds($0.duration),
                "input": $0.input, "output": $0.output,
            ] },
            "marks": marks.map { ["label": $0.label, "at": seconds($0.at)] },
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// A self-contained interactive debugger page: waterfall, zoom, lane
    /// toggles, per-span timings/tokens/IO. Open in any browser.
    public static func html(label: String) async throws -> String {
        timelineViewerTemplate
            .replacingOccurrences(of: "TIMELINE_LABEL", with: label)
            .replacingOccurrences(of: "TIMELINE_DATA", with: String(decoding: try await json(), as: UTF8.self))
    }

    /// Where the process's wall time went, one line per model seat and tool.
    public static func summary() async -> String {
        let (requests, toolRuns, _) = await RequestTimeline.shared.snapshot()
        guard !requests.isEmpty else { return "timing: no model requests recorded" }
        func dist(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "p50 %.1fs · max %.1fs", sorted[sorted.count / 2], sorted.last ?? 0)
        }
        var lines = ["timing:"]
        for (model, group) in Dictionary(grouping: requests, by: \.model).sorted(by: { $0.key < $1.key }) {
            let failures = group.count(where: { !$0.succeeded })
            lines.append("  \(model) — \(group.count) requests"
                + (failures > 0 ? " (\(failures) failed)" : "")
                + String(format: " · %.0fs busy", group.map { seconds($0.total) }.reduce(0, +))
                + " · ttft \(dist(group.map { seconds($0.firstToken) }))"
                + " · total \(dist(group.map { seconds($0.total) }))"
                + String(format: " · gate max %.1fs", group.map { seconds($0.gateWait) }.max() ?? 0))
        }
        for (tool, runs) in Dictionary(grouping: toolRuns, by: \.tool).sorted(by: { $0.key < $1.key }) {
            lines.append("  tool \(tool) — \(runs.count) runs"
                + String(format: " · %.0fs total", runs.map { seconds($0.duration) }.reduce(0, +))
                + " · \(dist(runs.map { seconds($0.duration) }))")
        }
        return lines.joined(separator: "\n")
    }
}
