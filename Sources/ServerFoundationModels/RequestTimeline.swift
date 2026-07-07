// Always-on, in-process timing capture for model requests and tool runs.
//
// Instruments-style visibility without Instruments: every ChatCompletions
// request records how long it waited on the concurrency gate, how long the
// connect took, when the first stream event arrived, and its total duration —
// and the session loop records how long each tool execution ran. A CLI
// pipeline prints the summary at the end of a run; a server could export it.
// Memory is bounded; recording is a single actor hop per request.

/// One model request, measured at the transport — with enough of the
/// request's content to debug a run from the timeline alone.
public struct ModelRequestTiming: Sendable {
    public let model: String
    /// When the request started, on the timeline's clock — spans plotted
    /// against this reconstruct the run as a waterfall.
    public let start: Duration
    /// Time spent queued behind `setMaxConcurrentRequests` before starting.
    public let gateWait: Duration
    /// Request start → response headers.
    public let connect: Duration
    /// Request start → first stream event (≈ time to first token).
    public let firstToken: Duration
    /// Request start → stream fully consumed.
    public let total: Duration
    public let succeeded: Bool
    /// Head of the request's LAST prompt entry — identifies the step
    /// ("Research: Financials…", "Now report your findings…").
    public let promptExcerpt: String
    /// Head of the streamed response text.
    public let responseExcerpt: String
    public let inputTokens: Int
    public let outputTokens: Int
}

/// One tool execution inside a session's tool-call loop.
public struct ToolRunTiming: Sendable {
    public let tool: String
    /// When the tool run started, on the timeline's clock.
    public let start: Duration
    public let duration: Duration
    /// The call's arguments JSON, clipped.
    public let input: String
    /// Head of what the tool returned.
    public let output: String
}

/// A caller-defined moment ("identity done", "pillars started") for
/// labeling phases when the timeline is rendered.
public struct TimelineMark: Sendable {
    public let label: String
    public let at: Duration
}

public actor RequestTimeline {
    public static let shared = RequestTimeline()

    /// Backstop against unbounded growth in long-lived processes — a research
    /// run records a few hundred entries; past the cap the oldest fall off.
    private static let capacity = 20_000

    /// Zero point for every `start`/`at` offset.
    private let epoch = ContinuousClock().now

    private var requests: [ModelRequestTiming] = []
    private var toolRuns: [ToolRunTiming] = []
    private var marks: [TimelineMark] = []

    /// Now, on the timeline's clock.
    nonisolated func offset(of instant: ContinuousClock.Instant = ContinuousClock().now) -> Duration {
        instant - epoch
    }

    func record(_ timing: ModelRequestTiming) {
        requests.append(timing)
        if requests.count > Self.capacity { requests.removeFirst(requests.count - Self.capacity) }
    }

    func record(_ timing: ToolRunTiming) {
        toolRuns.append(timing)
        if toolRuns.count > Self.capacity { toolRuns.removeFirst(toolRuns.count - Self.capacity) }
    }

    /// Label a moment ("identity done") for phase context in rendered timelines.
    public func mark(_ label: String) {
        marks.append(TimelineMark(label: label, at: offset()))
    }

    /// Times tool-shaped work that happens OUTSIDE a session's tool loop —
    /// mechanical fetches, preflight probes — so timelines show the work
    /// wrapping its nested model calls instead of orphaned requests.
    nonisolated public func measureToolRun<T: Sendable>(
        _ tool: String,
        input: String,
        output: @Sendable (T) -> String,
        body: () async throws -> T
    ) async rethrows -> T {
        let started = ContinuousClock().now
        do {
            let result = try await body()
            await record(ToolRunTiming(
                tool: tool, start: offset(of: started),
                duration: ContinuousClock().now - started,
                input: String(input.prefix(400)),
                output: String(output(result).prefix(600))
            ))
            return result
        } catch {
            await record(ToolRunTiming(
                tool: tool, start: offset(of: started),
                duration: ContinuousClock().now - started,
                input: String(input.prefix(400)),
                output: "threw: \(String(describing: error).prefix(300))"
            ))
            throw error
        }
    }

    public func snapshot() -> (requests: [ModelRequestTiming], toolRuns: [ToolRunTiming], marks: [TimelineMark]) {
        (requests, toolRuns, marks)
    }

    public func reset() {
        requests = []
        toolRuns = []
        marks = []
    }
}

/// Same-task scratchpad the executor fills in while streaming; not Sendable
/// on purpose — it never leaves the request's task.
final class RequestTimingBox {
    var connectAt: ContinuousClock.Instant?
    var firstEventAt: ContinuousClock.Instant?
    var responseExcerpt = ""
    var inputTokens = 0
    var outputTokens = 0

    func appendResponse(_ text: String) {
        guard responseExcerpt.utf8.count < 600 else { return }
        responseExcerpt += text
        if responseExcerpt.count > 600 { responseExcerpt = String(responseExcerpt.prefix(600)) }
    }
}
