import Foundation
import os

public final class SampleRateTracker: @unchecked Sendable {

    public enum Report: Equatable, Sendable {
        case insufficient
        case stable(measured: Double)
        case drift(measured: Double)
    }

    public let declaredRate: Double
    public let minimumDuration: TimeInterval
    public let divergenceThreshold: Double

    private struct State {
        var frames: Int64 = 0
        var wallClock: TimeInterval = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init(
        declaredRate: Double,
        minimumDuration: TimeInterval = 3.0,
        divergenceThreshold: Double = 0.05
    ) {
        self.declaredRate = declaredRate
        self.minimumDuration = minimumDuration
        self.divergenceThreshold = divergenceThreshold
    }

    @discardableResult
    public func ingest(frameCount: Int, wallClock: TimeInterval) -> Report {
        lock.withLock { state in
            state.frames += Int64(frameCount)
            state.wallClock += wallClock

            guard state.wallClock >= minimumDuration else {
                return .insufficient
            }

            let measured = Double(state.frames) / state.wallClock
            let divergence = abs(measured - declaredRate) / declaredRate

            guard divergence > divergenceThreshold else {
                return .stable(measured: measured)
            }
            return .drift(measured: measured)
        }
    }

    public func reset() {
        lock.withLock { $0 = State() }
    }
}
