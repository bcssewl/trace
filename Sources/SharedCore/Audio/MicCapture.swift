@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation
import os

public final class MicCapture: @unchecked Sendable {

    public struct Diagnostics: Sendable {
        public let isRunning: Bool
        public let inputDeviceName: String
        public let declaredSampleRate: Double
        public let framesObserved: Int64
        public let secondsObserved: TimeInterval
        public let voiceProcessingEnabled: Bool
    }

    /// Legacy single-shot stream kept for the few call sites that still grab
    /// `mic.buffers` directly.
    ///
    /// New code should call `subscribe()` instead —
    /// it returns a fresh AsyncStream per call, which is what lets multiple
    /// cycles consume the mic independently. Without this, the second
    /// `start()` would have no consumer because the original stream was
    /// already iterated/finished in the first cycle.
    public let buffers: AsyncStream<AVAudioPCMBuffer>
    private let buffersContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    /// Per-subscriber continuations.
    ///
    /// Each `subscribe()` adds one; on
    /// termination the continuation is removed automatically.
    private let subscribersLock = OSAllocatedUnfairLock<[UUID: AsyncStream<AVAudioPCMBuffer>.Continuation]>(
        initialState: [:])

    private let isRunning = SyncBool(initial: false)
    private let inputDeviceName = SyncString(initial: "")

    // `engine`, `configChangeObserver` and `rateTracker` are mutated ONLY on
    // `control`'s queue (start/stop/teardown/rebuild bodies). That single
    // serial context is what makes the drift rebuild — previously fired from
    // the Core Audio IO thread via an unstructured Task with no exclusion —
    // safe against a concurrent stop()/teardown() using the same engine.
    private var engine: AVAudioEngine?
    private let voiceProcessingFlag = SyncBool(initial: false)
    private var configChangeObserver: NSObjectProtocol?
    private var rateTracker: SampleRateTracker
    private let framesObservedLock = OSAllocatedUnfairLock(initialState: Int64(0))
    private let secondsObservedLock = OSAllocatedUnfairLock(initialState: TimeInterval(0))

    /// Serialises start/stop/teardown/rebuild; coalesces drift-rebuild storms
    /// (every tap callback during a drift can request one).
    private let control = SerialRebuildCoordinator(label: "app.trace.audio.mic.control")

    private let onHealthEventBox = OSAllocatedUnfairLock<(@Sendable (CaptureHealthEvent) -> Void)?>(
        initialState: nil)

    /// Observe capture health: drift/config-change rebuilds and rebuild
    /// failures. `.rebuildFailed` means the mic is no longer capturing.
    public func setOnHealthEvent(_ closure: @escaping @Sendable (CaptureHealthEvent) -> Void) {
        onHealthEventBox.withLock { $0 = closure }
    }

    /// Pending delayed full-teardown.
    ///
    /// The engine is kept WARM (built but stopped)
    /// between rapid dictations so each starts instantly; if no capture resumes
    /// within the idle window we fully release the mic hardware (BAS-78).
    private let idleTeardown = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private static let idleTeardownSeconds: TimeInterval = 120

    public init(voiceProcessingEnabled: Bool = false) {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.buffers = stream
        self.buffersContinuation = continuation
        self.voiceProcessingFlag.value = voiceProcessingEnabled
        self.rateTracker = SampleRateTracker(declaredRate: 48_000)
    }

    /// Multi-subscriber buffer stream.
    ///
    /// Each call returns a fresh AsyncStream
    /// that receives a copy of every mic buffer until the iterator is
    /// cancelled. Use this from dictation/meeting/voice-memo cycles so each
    /// cycle gets its own independent consumer.
    public func subscribe() -> AsyncStream<AVAudioPCMBuffer> {
        let id = UUID()
        let lock = subscribersLock
        return AsyncStream<AVAudioPCMBuffer> { continuation in
            lock.withLock { $0[id] = continuation }
            continuation.onTermination = { _ in
                _ = lock.withLock { dict -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
                    dict.removeValue(forKey: id)
                }
            }
        }
    }

    deinit {
        teardown()
        buffersContinuation.finish()
        // Snapshot + clear the subscribers UNDER the lock, then `finish()` them
        // OUTSIDE it. `Continuation.finish()` synchronously invokes each stream's
        // `onTermination` (set in `subscribe()`), which re-acquires
        // `subscribersLock` to remove itself — doing that while still holding the
        // lock re-enters a non-recursive `OSAllocatedUnfairLock` and TRAPS (the
        // crash seen tearing the mic down on a model switch). Finishing outside the
        // lock means `onTermination` finds the lock free, and its `removeValue` is
        // a harmless no-op since we already cleared the dictionary.
        let pending = subscribersLock.withLock { subs -> [AsyncStream<AVAudioPCMBuffer>.Continuation] in
            let values = Array(subs.values)
            subs.removeAll()
            return values
        }
        for sub in pending { sub.finish() }
    }

    public func setVoiceProcessing(enabled: Bool) {
        voiceProcessingFlag.value = enabled
    }

    public func start() throws {
        try control.withExclusiveControl {
            guard isRunning.compareAndSwap(expected: false, desired: true) else { return }
            cancelIdleTeardown()
            // Measure start latency + which path we took, so "is it actually faster?"
            // has a hard number in the console: COLD = engine built from scratch, WARM
            // = already-built engine just resumed (BAS-78). Watch two back-to-back
            // dictations: the first logs cold (~hundreds of ms), the next warm (~single
            // digits) — that gap is the dropped-first-words lag we removed.
            let startClock = DispatchTime.now()
            let wasWarm = engine != nil
            do {
                // Build the engine once and keep it WARM across cycles (BAS-78): the
                // first dictation (or one after a long idle) pays the build cost; every
                // one after just resumes the already-built engine — no cold-start lag
                // clipping your opening words. `eng.start()` turns the mic on (orange
                // dot); between cycles the engine is stopped (no dot) but stays ready.
                if engine == nil { try buildEngineOnQueue() }
                guard let eng = engine else {
                    isRunning.value = false
                    return
                }
                if !eng.isRunning {
                    eng.prepare()
                    try eng.start()
                }
                let ms = Int(
                    (Double(DispatchTime.now().uptimeNanoseconds &- startClock.uptimeNanoseconds) / 1_000_000)
                        .rounded())
                Loggers.audio.info(
                    "MicCapture capturing (\(wasWarm ? "warm" : "cold", privacy: .public) start, \(ms, privacy: .public)ms)"
                )
            } catch {
                isRunning.value = false
                teardownOnQueue()
                if case .denied = AudioPermissions.currentMicStatus() {
                    throw TraceError.permissionDenied(kind: .microphone)
                }
                throw error
            }
        }
    }

    public func stop() {
        control.withExclusiveControl {
            guard isRunning.compareAndSwap(expected: true, desired: false) else { return }
            // Don't tear down — just stop the audio flow (mic off, orange dot off) and
            // keep the engine WARM so the NEXT dictation starts instantly (BAS-78). A
            // delayed teardown releases the mic hardware if no capture resumes within
            // the idle window, so we never hold the device forever.
            engine?.stop()
            Loggers.audio.info("MicCapture idle (warm; releases in \(Int(Self.idleTeardownSeconds))s if unused)")
            scheduleIdleTeardown()
            // NOTE: per-subscriber + `buffers` continuations are intentionally NOT
            // finished here — they must survive across start/stop so re-using the mic
            // delivers samples on the next cycle. Finalized only in deinit/teardown.
        }
    }

    /// Schedule the full teardown after the idle window.
    ///
    /// Cancelled by the next
    /// `start()`, so rapid in-and-out dictation keeps the engine warm.
    private func scheduleIdleTeardown() {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTeardownSeconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.isRunning.value else { return }
            self.teardown()
        }
        idleTeardown.withLock { pending in
            pending?.cancel()
            pending = task
        }
    }

    private func cancelIdleTeardown() {
        idleTeardown.withLock { pending in
            pending?.cancel()
            pending = nil
        }
    }

    /// Full teardown — remove the tap, stop + release the engine and the mic
    /// hardware.
    ///
    /// Run by the idle timer (after the warm window) or by `deinit`.
    public func teardown() {
        control.withExclusiveControl {
            teardownOnQueue()
        }
    }

    /// Control-queue only.
    private func teardownOnQueue() {
        cancelIdleTeardown()
        isRunning.value = false
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        Loggers.audio.info("MicCapture torn down (cold)")
    }

    public func diagnostics() -> Diagnostics {
        // Reads `rateTracker` (control-queue protected), so take the queue.
        control.withExclusiveControl {
            Diagnostics(
                isRunning: isRunning.value,
                inputDeviceName: inputDeviceName.value,
                declaredSampleRate: rateTracker.declaredRate,
                framesObserved: framesObservedLock.withLock { $0 },
                secondsObserved: secondsObservedLock.withLock { $0 },
                voiceProcessingEnabled: voiceProcessingFlag.value)
        }
    }

    /// Builds + prepares the engine and installs the tap, but does NOT start
    /// audio flow — `start()` does that.
    ///
    /// Keeping a built-but-stopped engine warm
    /// between cycles is what makes the next dictation instant (BAS-78).
    /// Control-queue only.
    private func buildEngineOnQueue() throws {
        let eng = AVAudioEngine()
        let input = eng.inputNode

        do {
            try input.setVoiceProcessingEnabled(voiceProcessingFlag.value)
        } catch {
            Loggers.audio.warning(
                "setVoiceProcessingEnabled failed: \(error.localizedDescription, privacy: .public)")
        }

        let nativeFormat = input.outputFormat(forBus: 0)
        let declaredRate = nativeFormat.sampleRate
        self.rateTracker = SampleRateTracker(declaredRate: declaredRate)
        let trackerForRun = self.rateTracker

        let deviceName = (try? Self.fetchCurrentInputDeviceName()) ?? "unknown"
        inputDeviceName.value = deviceName
        let isBuiltIn = AudioFormat.isBuiltInMicName(deviceName)

        Loggers.audio.info(
            "MicCapture engine built: device=\(deviceName, privacy: .public) rate=\(declaredRate, privacy: .public) channels=\(nativeFormat.channelCount, privacy: .public) builtIn=\(isBuiltIn, privacy: .public)"
        )

        let continuation = buffersContinuation
        let framesLock = framesObservedLock
        let secondsLock = secondsObservedLock

        let tapBufferSize: AVAudioFrameCount = 4_096
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nativeFormat) {
            [weak self] inBuffer, _ in
            let frames = Int(inBuffer.frameLength)
            let dt = TimeInterval(frames) / declaredRate

            framesLock.withLock { $0 += Int64(frames) }
            secondsLock.withLock { $0 += dt }

            let report = trackerForRun.ingest(frameCount: frames, wallClock: dt)
            if case .drift(let measured) = report {
                Loggers.audio.warning(
                    "MicCapture rate drift: declared=\(declaredRate, privacy: .public) measured=\(measured, privacy: .public). Rebuilding engine."
                )
                // Serialised + coalesced: a drift storm (every callback fires
                // this until the rebuild lands) collapses into one rebuild
                // instead of racing the engine teardown from the IO thread.
                self?.requestRebuild(
                    reason: "sample-rate drift",
                    trigger: .driftTriggeredRebuild(declaredHz: declaredRate, measuredHz: measured))
                return
            }

            let mono: AVAudioPCMBuffer
            if isBuiltIn || inBuffer.format.channelCount > 1 {
                do {
                    mono = try AudioBufferHelpers.extractChannelZero(inBuffer)
                } catch {
                    Loggers.audio.error(
                        "MicCapture channel-0 extract failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            } else {
                mono = inBuffer
            }
            continuation.yield(mono)
            // Fan out to every active subscriber created via `subscribe()`.
            // Tap blocks run on the audio I/O thread; brief locked snapshot
            // copy keeps yield calls outside the lock.
            let snapshot: [AsyncStream<AVAudioPCMBuffer>.Continuation] =
                self?.subscribersLock.withLock { Array($0.values) } ?? []
            for sub in snapshot {
                sub.yield(mono)
            }
        }

        eng.prepare()
        self.engine = eng
        // (Re)bind the config-change observer to THIS engine instance so a device
        // switch while warm still triggers a clean rebuild.
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        installConfigChangeObserverOnQueue()
    }

    /// Control-queue only.
    private func installConfigChangeObserverOnQueue() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Loggers.audio.info("AVAudioEngineConfigurationChange observed; rebuilding MicCapture")
            self?.requestRebuild(
                reason: "engine configuration change",
                trigger: .configurationChangeTriggeredRebuild)
        }
    }

    /// Request an engine rebuild. Serialised on the control queue; overlapping
    /// requests coalesce to at most one trailing rebuild. Safe from any thread
    /// including the audio IO tap (it never blocks on the rebuild itself).
    internal func requestRebuild(reason: String, trigger: CaptureHealthEvent? = nil) {
        let scheduled = control.requestRebuild { [weak self] in
            self?.performRebuildOnQueue()
        }
        if scheduled, let trigger {
            emitHealth(trigger)
        } else if !scheduled {
            Loggers.audio.info(
                "MicCapture rebuild request coalesced (\(reason, privacy: .public))")
        }
    }

    /// Control-queue only — invoked solely via `control.requestRebuild`.
    private func performRebuildOnQueue() {
        guard isRunning.value else { return }
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        do {
            try buildEngineOnQueue()
            engine?.prepare()
            try engine?.start()
            emitHealth(.rebuildSucceeded)
            Loggers.audio.info("MicCapture rebuilt; capture resumed")
        } catch {
            Loggers.audio.error(
                "MicCapture rebuild failed: \(error.localizedDescription, privacy: .public)")
            isRunning.value = false
            buffersContinuation.finish()
            // Loud failure: the mic is dead. The health event lets the runtime
            // tell the user instead of recording silence.
            emitHealth(.rebuildFailed(reason: error.localizedDescription))
        }
    }

    private func emitHealth(_ event: CaptureHealthEvent) {
        (onHealthEventBox.withLock { $0 })?(event)
    }

    private static func fetchCurrentInputDeviceName() throws -> String {
        let id = try DeviceWatcher.currentDefaultInputDeviceID()
        return try DeviceWatcher.deviceName(for: id)
    }
}
