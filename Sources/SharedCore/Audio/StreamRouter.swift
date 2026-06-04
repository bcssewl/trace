@preconcurrency import AVFoundation
import Foundation
import os

public actor StreamRouter {

    public struct Subscriber: Sendable {
        public let id: UUID
        public let label: String
        let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    }

    public private(set) var subscribers: [Subscriber] = []
    private var isFinished = false

    public init() {}

    public nonisolated func subscribe(label: String) -> AsyncStream<AVAudioPCMBuffer> {
        let id = UUID()
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            let subscriber = Subscriber(id: id, label: label, continuation: continuation)
            Task { [weak self] in
                await self?.addSubscriber(subscriber)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.unsubscribe(id: id)
                }
            }
        }
        Loggers.audio.debug("StreamRouter subscribing: \(label, privacy: .public)")
        return stream
    }

    private func addSubscriber(_ subscriber: Subscriber) {
        guard !isFinished else {
            subscriber.continuation.finish()
            return
        }
        subscribers.append(subscriber)
    }

    public func unsubscribe(id: UUID) {
        if let idx = subscribers.firstIndex(where: { $0.id == id }) {
            let removed = subscribers.remove(at: idx)
            removed.continuation.finish()
            Loggers.audio.debug("StreamRouter unsubscribed: \(removed.label, privacy: .public)")
        }
    }

    public func publish(_ buffer: AVAudioPCMBuffer) {
        guard !isFinished else { return }
        for sub in subscribers {
            sub.continuation.yield(buffer)
        }
    }

    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        for sub in subscribers {
            sub.continuation.finish()
        }
        subscribers.removeAll()
        Loggers.audio.info("StreamRouter finished")
    }

    public var subscriberCount: Int {
        subscribers.count
    }
}
