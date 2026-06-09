import Foundation
import os

/// Serialises every pipeline mutation (start / stop / rebuild) of an audio
/// capture through one serial dispatch queue, and coalesces rebuild requests.
///
/// Why: `SystemAudioCapture.rebuild()` used to be reachable concurrently from
/// the silence-watchdog timer (its own queue) and the device-watcher task, with
/// no mutual exclusion. Two overlapping tearDown/buildPipeline passes can hand
/// stale CoreAudio handles to the HAL, which can crash the whole process.
/// `MicCapture.rebuildAfterDrift()` had the same shape (fired from the audio IO
/// thread via an unstructured `Task`). Both captures now funnel every mutation
/// through one of these.
///
/// Contract:
/// - `withExclusiveControl` runs a start/stop body synchronously on the queue,
///   so it can never interleave with an in-flight rebuild.
/// - `requestRebuild` schedules the rebuild body asynchronously on the same
///   queue. Requests arriving while one is already queued are dropped (the
///   queued pass covers them); requests arriving while one is *executing*
///   schedule exactly ONE trailing pass — N overlapping requests collapse to
///   at most one rebuild after the current one, never N.
/// - `isRebuildPendingOrActive` lets periodic checks (the silence watchdog)
///   stand down while a rebuild is queued or in flight.
public final class SerialRebuildCoordinator: @unchecked Sendable {

    private let queue: DispatchQueue
    /// True from the moment a rebuild block is enqueued until that block begins
    /// executing. Guarded by `stateLock`.
    private var rebuildQueued = false
    /// True while a rebuild body is executing on the queue. Guarded by `stateLock`.
    private var rebuildActive = false
    private let stateLock = OSAllocatedUnfairLock<Void>(initialState: ())

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    /// A rebuild is queued or currently executing.
    public var isRebuildPendingOrActive: Bool {
        stateLock.withLock { _ in rebuildQueued || rebuildActive }
    }

    /// Run `body` exclusively: no rebuild (and no other exclusive body) can
    /// overlap it. Synchronous — use for start/stop/teardown paths.
    ///
    /// Must NOT be called from within a body already running on this
    /// coordinator (it would deadlock); nested work belongs in plain private
    /// `…OnQueue` helpers on the owning capture.
    public func withExclusiveControl<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    /// Request a rebuild. Returns `true` if this request scheduled a pass,
    /// `false` if it coalesced into one that is already queued.
    ///
    /// Safe to call from any thread, including audio IO callbacks (it only
    /// takes an unfair lock and enqueues asynchronously — it never blocks on
    /// the rebuild itself).
    @discardableResult
    public func requestRebuild(_ body: @escaping @Sendable () -> Void) -> Bool {
        let scheduled = stateLock.withLock { _ -> Bool in
            guard !rebuildQueued else { return false }
            rebuildQueued = true
            return true
        }
        guard scheduled else { return false }
        queue.async { [self] in
            stateLock.withLock { _ in
                rebuildQueued = false
                rebuildActive = true
            }
            body()
            stateLock.withLock { _ in rebuildActive = false }
        }
        return true
    }
}

/// Health signal emitted by an audio capture when it recovers (or fails to
/// recover) on its own. Surfaced so the UI can show e.g. "audio capture
/// recovered" instead of degrading silently.
public enum CaptureHealthEvent: Sendable, Equatable {
    /// The all-zero watchdog saw `silentSeconds` of digital silence while the
    /// OS reported the device running; the capture pipeline is being rebuilt.
    case watchdogTriggeredRebuild(silentSeconds: TimeInterval)
    /// The default audio device changed; the capture pipeline is being rebuilt.
    case deviceChangeTriggeredRebuild
    /// Measured sample rate drifted from the declared rate; the engine is
    /// being rebuilt.
    case driftTriggeredRebuild(declaredHz: Double, measuredHz: Double)
    /// The audio engine reported a configuration change (e.g. AirPods route
    /// switch); the engine is being rebuilt.
    case configurationChangeTriggeredRebuild
    /// A rebuild completed and capture resumed.
    case rebuildSucceeded
    /// A rebuild failed; capture has STOPPED and its buffer stream is finished.
    /// Callers must surface this loudly — audio is no longer being recorded.
    case rebuildFailed(reason: String)
}
