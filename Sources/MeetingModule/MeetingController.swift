import Foundation

public actor MeetingController {
    private let audio: any MeetingAudioControlling
    private let storage: any MeetingStorageWriting
    private let merger: any MeetingMerging
    private var session: CaptureSession?
    private var title: String = ""
    private let clock: @Sendable () -> Date

    public init(
        audio: any MeetingAudioControlling,
        storage: any MeetingStorageWriting,
        merger: any MeetingMerging = NoopMeetingMerger(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.audio = audio
        self.storage = storage
        self.merger = merger
        self.clock = clock
    }

    public func start(title: String) async throws -> MeetingSnapshot {
        let formatter = ISO8601DateFormatter()
        let id = "session_" + formatter.string(from: clock()).replacingOccurrences(of: ":", with: "-")
        var next = CaptureSession(id: id)
        try next.starting(now: clock())
        do {
            try await audio.startMic()
            try await audio.startSystem()
            try await storage.createSession(id: id, title: title)
        } catch {
            try? await audio.stopAll()
            throw error
        }
        try next.recording()
        self.session = next
        self.title = title
        return snapshot(from: next)
    }

    public func finalize() async throws {
        guard var current = session else { throw MeetingError.missingActiveSession }
        try current.finalizing(now: clock())
        try await audio.stopAll()
        let context = try await storage.finalizeTranscript(id: current.id)
        try await merger.merge(context)
        try current.done()
        session = current
    }

    public func currentSnapshot() -> MeetingSnapshot? {
        session.map(snapshot(from:))
    }

    private func snapshot(from session: CaptureSession) -> MeetingSnapshot {
        MeetingSnapshot(sessionID: session.id, title: title, state: session.state)
    }
}
