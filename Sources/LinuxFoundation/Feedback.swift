// LanguageModelFeedback — structured feedback about model output, serialized
// by logFeedbackAttachment for attachment to bug reports. Mirrors
// FoundationModels (SDK 27).

import Foundation

public struct LanguageModelFeedback {
    public enum Sentiment: Sendable, CaseIterable, Hashable {
        case positive
        case negative
        case neutral
    }

    public struct Issue: Sendable {
        public enum Category: Sendable, CaseIterable, Hashable {
            case unhelpful
            case tooVerbose
            case didNotFollowInstructions
            case incorrect
            case stereotypeOrBias
            case suggestiveOrSexual
            case vulgarOrOffensive
            case triggeredGuardrailUnexpectedly
        }

        public var category: Category
        public var explanation: String?

        public init(category: Category, explanation: String? = nil) {
            self.category = category
            self.explanation = explanation
        }
    }
}

extension LanguageModelSession {
    /// Serializes feedback about the latest exchange as a JSON attachment.
    @discardableResult
    public func logFeedbackAttachment(
        sentiment: LanguageModelFeedback.Sentiment?,
        issues: [LanguageModelFeedback.Issue] = [],
        desiredOutput: Transcript.Entry? = nil
    ) -> Data {
        var members: [JSONNode.Member] = []
        if let sentiment {
            members.append(.init(key: "sentiment", value: .string(String(describing: sentiment))))
        }
        members.append(.init(key: "issues", value: .array(issues.map { issue in
            var issueMembers: [JSONNode.Member] = [
                .init(key: "category", value: .string(String(describing: issue.category)))
            ]
            if let explanation = issue.explanation {
                issueMembers.append(.init(key: "explanation", value: .string(explanation)))
            }
            return .object(issueMembers)
        })))
        members.append(.init(key: "transcript", value: .array(transcript.map { entry in
            .string(String(describing: entry))
        })))
        if let desiredOutput {
            members.append(.init(key: "desiredOutput", value: .string(String(describing: desiredOutput))))
        }
        return Data(JSONNode.object(members).serialized.utf8)
    }

    @discardableResult
    public func logFeedbackAttachment(
        sentiment: LanguageModelFeedback.Sentiment?,
        issues: [LanguageModelFeedback.Issue] = [],
        desiredResponseContent: (any ConvertibleToGeneratedContent)?
    ) -> Data {
        let entry = desiredResponseContent.map { content in
            Transcript.Entry.response(Transcript.Response(
                segments: [.structure(.init(content: content.generatedContent))]
            ))
        }
        return logFeedbackAttachment(sentiment: sentiment, issues: issues, desiredOutput: entry)
    }

    @discardableResult
    public func logFeedbackAttachment(
        sentiment: LanguageModelFeedback.Sentiment?,
        issues: [LanguageModelFeedback.Issue] = [],
        desiredResponseText: String?
    ) -> Data {
        let entry = desiredResponseText.map { content in
            Transcript.Entry.response(Transcript.Response(
                segments: [.text(.init(content: content))]
            ))
        }
        return logFeedbackAttachment(sentiment: sentiment, issues: issues, desiredOutput: entry)
    }
}
