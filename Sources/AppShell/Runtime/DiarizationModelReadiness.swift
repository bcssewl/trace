import Foundation
import Observation

/// The single rule deciding whether a meeting runs speaker diarization.
///
/// It
/// collapses to the standard You / Others behavior unless the (beta) feature is
/// explicitly on AND the on-device models are confirmed ready, so a disabled or
/// not-yet-prepared state never half-runs.
public struct DiarizationActivation: Equatable, Sendable {
    /// Run the cheap live `remote_N` labeling during capture.
    public let useLive: Bool
    /// Record the system audio + run the offline refinement pass at finalize.
    public let useOffline: Bool

    public init(useLive: Bool, useOffline: Bool) {
        self.useLive = useLive
        self.useOffline = useOffline
    }

    public static func resolve(
        featureEnabled: Bool, modelsReady: Bool, liveEnabled: Bool, offlineEnabled: Bool
    ) -> DiarizationActivation {
        guard featureEnabled, modelsReady else {
            return DiarizationActivation(useLive: false, useOffline: false)
        }
        return DiarizationActivation(useLive: liveEnabled, useOffline: offlineEnabled)
    }

    /// Whether any model needs preparing — i.e. the feature is on and at least
    /// one sub-pass is enabled.
    ///
    /// Drives the background model download/compile.
    public static func needsModels(featureEnabled: Bool, liveEnabled: Bool, offlineEnabled: Bool) -> Bool {
        featureEnabled && (liveEnabled || offlineEnabled)
    }
}

/// Observable gate the app checks before enabling diarization for a meeting.
///
/// Seeds from a persisted "prepared before" flag (the FluidAudio model cache
/// survives launches), and `ready` is **sticky**: once ready, a later re-prepare
/// or failure can't demote a meeting back to You / Others mid-session.
@MainActor
@Observable
public final class DiarizationModelReadiness {
    public enum Status: Sendable, Equatable {
        case unprepared, preparing, ready, failed
    }

    public private(set) var status: Status

    public var isReady: Bool { status == .ready }

    public init(preparedBefore: Bool) {
        status = preparedBefore ? .ready : .unprepared
    }

    public func markPreparing() {
        guard status != .ready else { return }
        status = .preparing
    }

    public func markReady() {
        status = .ready
    }

    public func markFailed() {
        guard status != .ready else { return }
        status = .failed
    }
}
