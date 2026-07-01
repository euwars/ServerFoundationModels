// Per-session xAI chaining state. One instance per LanguageModelSession.

import Foundation

public final class XAIConversationState: @unchecked Sendable {
    private let lock = NSLock()

    /// Stable key for xAI prompt prefix caching across all hops in a conversation.
    public let promptCacheKey: String

    private var storedTurns: [StoredTurn] = []
    private var lastResponseId: String?
    private var lastRawOutput: Data?
    private var lastModelId: String?
    private var expiresAt: Date?

    /// Response ID from the current `respond()` tool-loop round.
    private var inTurnResponseId: String?
    /// Transcript entry count sent on the last executor call within the current turn.
    private var lastSentEntryCount: Int = 0
    /// Whether we are inside a multi-round tool loop for the current user turn.
    private var inToolLoop: Bool = false

    private static let ttl: TimeInterval = 25 * 24 * 3600

    public init(promptCacheKey: String = UUID().uuidString) {
        self.promptCacheKey = promptCacheKey
    }

    struct StoredTurn: Sendable {
        var prompt: String
        var rawOutput: Data?
        var outputText: String
        var modelId: String
    }

    public enum ThreadingMode: Sendable {
        case fresh
        case threaded(previousResponseId: String)
        case inline
    }

    // MARK: - Turn lifecycle

    func beginUserTurn(transcriptEntryCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        inToolLoop = false
        inTurnResponseId = nil
        lastSentEntryCount = transcriptEntryCount
    }

    func beginToolLoopRound(transcriptEntryCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        inToolLoop = true
        if lastSentEntryCount == 0 {
            lastSentEntryCount = transcriptEntryCount
        }
    }

    public func threadingMode(model: XAIModel, now: Date = Date()) -> ThreadingMode {
        lock.lock()
        defer { lock.unlock() }

        if inToolLoop, let roundId = inTurnResponseId {
            return .threaded(previousResponseId: roundId)
        }

        if let responseId = lastResponseId,
            let expires = expiresAt,
            expires > now,
            model.supportsThreading,
            lastModelId.map({ !$0.contains("multi-agent") }) ?? true {
            return .threaded(previousResponseId: responseId)
        }

        if !storedTurns.isEmpty {
            return .inline
        }

        return .fresh
    }

    func lastSentIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return lastSentEntryCount
    }

    func storedTurnChain() -> [StoredTurn] {
        lock.lock()
        defer { lock.unlock() }
        return storedTurns
    }

    func recordExecutorSuccess(
        responseId: String?,
        rawOutput: Data?,
        outputText: String,
        userPrompt: String?,
        modelId: String,
        transcriptEntryCount: Int,
        turnCompleted: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        lastSentEntryCount = transcriptEntryCount

        if let responseId {
            if inToolLoop && !turnCompleted {
                inTurnResponseId = responseId
            } else {
                lastResponseId = responseId
                inTurnResponseId = nil
                expiresAt = Date().addingTimeInterval(Self.ttl)
            }
        }

        if let rawOutput {
            lastRawOutput = rawOutput
        }
        lastModelId = modelId

        if turnCompleted, let userPrompt {
            storedTurns.append(StoredTurn(
                prompt: userPrompt,
                rawOutput: rawOutput ?? lastRawOutput,
                outputText: outputText,
                modelId: modelId
            ))
            inToolLoop = false
            inTurnResponseId = nil
        }
    }

    func clearThreadingForFallback() {
        lock.lock()
        defer { lock.unlock() }
        inTurnResponseId = nil
        lastResponseId = nil
    }
}