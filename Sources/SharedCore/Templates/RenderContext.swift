import Foundation

public struct RenderContext: Sendable, Hashable {
    public let transcript: String
    public let scratchpad: String
    public let calendarUntrusted: String
    public let priorNotesUntrusted: String
    public let projectVocab: String
    public let conversationState: String

    public init(
        transcript: String, scratchpad: String,
        calendarUntrusted: String, priorNotesUntrusted: String,
        projectVocab: String, conversationState: String
    ) {
        self.transcript = transcript
        self.scratchpad = scratchpad
        self.calendarUntrusted = calendarUntrusted
        self.priorNotesUntrusted = priorNotesUntrusted
        self.projectVocab = projectVocab
        self.conversationState = conversationState
    }

    public static let empty = RenderContext(
        transcript: "", scratchpad: "",
        calendarUntrusted: "", priorNotesUntrusted: "",
        projectVocab: "", conversationState: ""
    )
}
