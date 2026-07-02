// Per-session xAI chaining state. One instance per LanguageModelSession.

import Foundation
import Synchronization

private struct ConversationState {
    var storedTurns: [XAIConversationState.StoredTurn] = []
    var lastResponseId: String?
    var lastRawOutput: Data?
    var lastModelId: String?
    var expiresAt: Date?
    var inTurnResponseId: String?
    var lastSentEntryCount: Int = 0
    var inToolLoop: Bool = false
}

/// @unchecked Sendable invariant: all mutable chaining fields live in `state`
/// and are accessed only through `Mutex.withLock`. One instance per session.
public final class XAIConversationState: @unchecked Sendable {
    private let state = Mutex(ConversationState())

    /// Stable key for xAI prompt prefix caching across all hops in a conversation.
    public let promptCacheKey: String

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
        state.withLock {
            $0.inToolLoop = false
            $0.inTurnResponseId = nil
            $0.lastSentEntryCount = transcriptEntryCount
        }
    }

    func beginToolLoopRound(transcriptEntryCount: Int) {
        state.withLock {
            $0.inToolLoop = true
            if $0.lastSentEntryCount == 0 {
                $0.lastSentEntryCount = transcriptEntryCount
            }
        }
    }

    public func threadingMode(model: XAIModel, now: Date = Date()) -> ThreadingMode {
        state.withLock { snapshot in
            if snapshot.inToolLoop, let roundId = snapshot.inTurnResponseId {
                return .threaded(previousResponseId: roundId)
            }

            if let responseId = snapshot.lastResponseId,
                let expires = snapshot.expiresAt,
                expires > now,
                model.supportsThreading,
                snapshot.lastModelId.map({ !$0.contains("multi-agent") }) ?? true {
                return .threaded(previousResponseId: responseId)
            }

            if !snapshot.storedTurns.isEmpty {
                return .inline
            }

            return .fresh
        }
    }

    func lastSentIndex() -> Int {
        state.withLock { $0.lastSentEntryCount }
    }

    func storedTurnChain() -> [StoredTurn] {
        state.withLock { $0.storedTurns }
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
        state.withLock { snapshot in
            snapshot.lastSentEntryCount = transcriptEntryCount

            if let responseId {
                if snapshot.inToolLoop && !turnCompleted {
                    snapshot.inTurnResponseId = responseId
                } else {
                    snapshot.lastResponseId = responseId
                    snapshot.inTurnResponseId = nil
                    snapshot.expiresAt = Date().addingTimeInterval(Self.ttl)
                }
            }

            if let rawOutput {
                snapshot.lastRawOutput = rawOutput
            }
            snapshot.lastModelId = modelId

            if turnCompleted, let userPrompt {
                snapshot.storedTurns.append(StoredTurn(
                    prompt: userPrompt,
                    rawOutput: rawOutput ?? snapshot.lastRawOutput,
                    outputText: outputText,
                    modelId: modelId
                ))
                snapshot.inToolLoop = false
                snapshot.inTurnResponseId = nil
            }
        }
    }

    func clearThreadingForFallback() {
        state.withLock {
            $0.inTurnResponseId = nil
            $0.lastResponseId = nil
        }
    }
}