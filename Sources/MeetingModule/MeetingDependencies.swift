import Foundation

public struct MeetingSnapshot: Sendable, Hashable, Codable {
    public let sessionID: String
    public let title: String
    public let state: CaptureSession.State

    public init(sessionID: String, title: String, state: CaptureSession.State) {
        self.sessionID = sessionID
        self.title = title
        self.state = state
    }
}

public struct FinalizedMeetingContext: Sendable, Hashable, Codable {
    public let sessionID: String
    public let transcriptJSONL: String
    public let scratchpadMarkdown: String
    public let calendarText: String
    public let priorNotesMarkdown: String

    public init(
        sessionID: String, transcriptJSONL: String, scratchpadMarkdown: String,
        calendarText: String, priorNotesMarkdown: String
    ) {
        self.sessionID = sessionID
        self.transcriptJSONL = transcriptJSONL
        self.scratchpadMarkdown = scratchpadMarkdown
        self.calendarText = calendarText
        self.priorNotesMarkdown = priorNotesMarkdown
    }
}

public protocol MeetingAudioControlling: Sendable {
    func startMic() async throws
    func startSystem() async throws
    func stopAll() async throws
}

public protocol MeetingStorageWriting: Sendable {
    func createSession(id: String, title: String) async throws
    func finalizeTranscript(id: String) async throws -> FinalizedMeetingContext
}

public protocol MeetingMerging: Sendable {
    func merge(_ context: FinalizedMeetingContext) async throws
}

public struct NoopMeetingMerger: MeetingMerging {
    public init() {}
    public func merge(_ context: FinalizedMeetingContext) async throws {}
}
