import Foundation

public struct CaptureSession: Sendable, Hashable, Codable, Identifiable {
    public enum State: String, Sendable, Codable, Hashable {
        case idle
        case starting
        case recording
        case finalizing
        case done
        case failed
    }

    public let id: String
    public private(set) var state: State
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?

    public init(id: String, state: State = .idle) {
        self.id = id
        self.state = state
    }

    public mutating func starting(now: Date = Date()) throws {
        try transition(from: [.idle], to: .starting)
        startedAt = now
    }

    public mutating func recording() throws {
        try transition(from: [.starting], to: .recording)
    }

    public mutating func finalizing(now: Date = Date()) throws {
        try transition(from: [.recording], to: .finalizing)
        endedAt = now
    }

    public mutating func done() throws {
        try transition(from: [.finalizing], to: .done)
    }

    public mutating func fail() {
        state = .failed
        endedAt = Date()
    }

    private mutating func transition(from allowed: Set<State>, to next: State) throws {
        guard allowed.contains(state) else {
            throw MeetingError.invalidTransition(from: state, to: next)
        }
        state = next
    }
}

public enum MeetingError: Error, Sendable, Equatable {
    case invalidTransition(from: CaptureSession.State, to: CaptureSession.State)
    case missingActiveSession
    case finalizeFailed(String)
}
