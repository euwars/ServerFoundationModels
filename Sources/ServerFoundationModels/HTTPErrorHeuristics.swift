// Shared HTTP heuristics for classifying model-server errors. Provider
// adapters map results onto LanguageModelError and the session-level taxonomy
// in SessionErrors.swift.

import Foundation

/// Shared provider-agnostic heuristics for classifying HTTP model-server errors.
enum HTTPErrorHeuristics {
    /// RFC 7231 Retry-After: delta-seconds or HTTP-date. Returns nil if unparseable.
    ///
    /// Feeds `LanguageModelError.rateLimited.resetDate` (session:
    /// `LanguageModelSession.GenerationError.rateLimited`).
    static func retryAfterDate(fromHeaderValue value: String, now: Date = Date()) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.date(from: trimmed)
    }

    /// True when statusCode/body indicate the prompt exceeded the model's context window.
    ///
    /// Providers commonly report this as HTTP 400/413; maps to
    /// `LanguageModelError.contextSizeExceeded` (session:
    /// `LanguageModelSession.GenerationError.exceededContextWindowSize`).
    static func isContextOverflow(statusCode: Int, body: String) -> Bool {
        let lowered = body.lowercased()
        return [400, 413].contains(statusCode)
            && (lowered.contains("context") || lowered.contains("maximum length"))
            && (lowered.contains("token") || lowered.contains("length") || lowered.contains("window"))
    }
}