// Same-task scratchpad the ChatCompletions executor fills in while streaming;
// not Sendable on purpose — it never leaves the request's task.

import Foundation

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
