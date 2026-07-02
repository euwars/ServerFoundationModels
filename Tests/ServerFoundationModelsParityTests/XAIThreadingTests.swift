import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAIThreadingTests {
    @Test func multiAgentModelIsNotThreadable() {
        let state = XAIConversationState()
        state.recordExecutorSuccess(
            responseId: "resp_multi",
            rawOutput: Data(),
            outputText: "done",
            userPrompt: "hello",
            modelId: XAIModel.grok4_20MultiAgent.id,
            transcriptEntryCount: 2,
            turnCompleted: true
        )
        let mode = state.threadingMode(model: .grok4_3)
        if case .inline = mode {
            // expected — multi-agent parent forces inline
        } else {
            Issue.record("expected inline mode for multi-agent parent, got \(mode)")
        }
    }

    @Test func freshConversationStartsFresh() {
        let state = XAIConversationState()
        let mode = state.threadingMode(model: .grok4_3)
        if case .fresh = mode {
            // expected
        } else {
            Issue.record("expected fresh mode, got \(mode)")
        }
    }

    @Test func liveResponseIdEnablesThreading() {
        let state = XAIConversationState()
        state.recordExecutorSuccess(
            responseId: "resp_live",
            rawOutput: Data("[{\"type\":\"message\"}]".utf8),
            outputText: "answer",
            userPrompt: "hello",
            modelId: XAIModel.grok4_3.id,
            transcriptEntryCount: 2,
            turnCompleted: true
        )
        let mode = state.threadingMode(model: .grok4_3)
        if case .threaded(let id) = mode {
            #expect(id == "resp_live")
        } else {
            Issue.record("expected threaded mode, got \(mode)")
        }
    }

    @Test func threadingContentElementErrorDetection() {
        let error = XAIError(
            status: 400,
            body: "Each message must have at least one content element"
        )
        #expect(XAIError.isThreadingContentElementError(error))
        #expect(!XAIError.isThreadingContentElementError(XAIError(status: 400, body: "other")))
    }

    @Test func mapsRetryAfterHeaderToResetDate() {
        let before = Date()
        let mapped = XAIErrorMapper.map(XAIError(status: 429, body: "too many", retryAfter: "60"))
        guard case .rateLimited(let payload) = mapped as? LanguageModelError else {
            Issue.record("expected LanguageModelError.rateLimited")
            return
        }
        guard let resetDate = payload.resetDate else {
            Issue.record("expected non-nil resetDate")
            return
        }
        let interval = resetDate.timeIntervalSince(before)
        #expect(interval >= 59)
        #expect(interval <= 62)
    }
}