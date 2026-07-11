// Process-global cap on concurrent in-flight model HTTP requests.

import ServerFoundationModels

/// Bounds how many chat-completions requests are in flight at once, across
/// every session and model in the process. Off by default.
///
/// Server pipelines that fan out dozens of parallel sessions otherwise
/// stampede a provider: requests queue provider-side while their client
/// timeout clocks run, and the burst surfaces as clustered timeouts rather
/// than an orderly slowdown. A cap turns the stampede into a queue on this
/// side of the wire, where waiting is free.
///
/// A permit spans exactly one HTTP request — from connect through the end of
/// body streaming — never a whole session turn. Tool handlers that call a
/// model themselves therefore cannot deadlock: the parent's permit is
/// already released while its tools run.
actor RequestGate {
    static let shared = RequestGate()

    private var limit: Int?
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `nil` or a non-positive limit removes the cap and admits all waiters.
    func configure(limit newLimit: Int?) {
        limit = newLimit.flatMap { $0 > 0 ? $0 : nil }
        admitWaiters()
    }

    private var hasCapacity: Bool {
        guard let limit else { return true }
        return inFlight < limit
    }

    private func admitWaiters() {
        while !waiters.isEmpty, hasCapacity {
            inFlight += 1
            waiters.removeFirst().resume()
        }
    }

    private func acquire() async {
        if hasCapacity {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        inFlight -= 1
        admitWaiters()
    }

    /// Runs `body` under a permit; waiting is FIFO. A task cancelled while
    /// waiting still receives its permit in turn and is expected to fail fast
    /// inside `body` — the transport checks cancellation before connecting.
    nonisolated func withPermit<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}

extension ChatCompletionsLanguageModel {
    /// Caps concurrent in-flight requests across every `ChatCompletions`
    /// session and model in the process — all providers and hosts combined.
    /// `nil` or a non-positive value removes the cap (the default).
    ///
    /// Set once at startup, before sessions start responding.
    public static func setMaxConcurrentRequests(_ limit: Int?) async {
        await RequestGate.shared.configure(limit: limit)
    }
}
