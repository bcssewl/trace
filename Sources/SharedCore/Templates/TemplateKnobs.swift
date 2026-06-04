import Foundation

public struct TemplateKnobs: Sendable, Codable, Hashable {
    public var tone: Tone
    public var audience: Audience
    public var quoteHandling: QuoteMode
    public var actionItemFormat: ActionItemFormat
    public var cloudRouting: CloudRoutingPolicy
    public var length: LengthTarget

    public init(
        tone: Tone, audience: Audience, quoteHandling: QuoteMode,
        actionItemFormat: ActionItemFormat, cloudRouting: CloudRoutingPolicy,
        length: LengthTarget
    ) {
        self.tone = tone
        self.audience = audience
        self.quoteHandling = quoteHandling
        self.actionItemFormat = actionItemFormat
        self.cloudRouting = cloudRouting
        self.length = length
    }

    public static let `default` = TemplateKnobs(
        tone: .conversational, audience: .internal_,
        quoteHandling: .paraphrase, actionItemFormat: .bulletedOwnerVerb,
        cloudRouting: .useGlobal, length: .standard
    )

    public enum Tone: String, Sendable, Codable, CaseIterable, Hashable {
        case formal, conversational, strictlyNeutral
    }

    public enum Audience: String, Sendable, Codable, CaseIterable, Hashable {
        case internal_ = "internal"
        case external
        case crmBound
    }

    public enum QuoteMode: String, Sendable, Codable, CaseIterable, Hashable {
        case paraphrase, verbatimForObjections, verbatimAlways
    }

    public enum ActionItemFormat: String, Sendable, Codable, CaseIterable, Hashable {
        case bulletedOwnerVerb, table, timelineChronological
        case none_ = "none"
    }

    public enum CloudRoutingPolicy: String, Sendable, Codable, CaseIterable, Hashable {
        case useGlobal, forceLocalOnly, cloudRequired
    }

    public enum LengthTarget: String, Sendable, Codable, CaseIterable, Hashable {
        case brief, standard, detailed
    }
}
