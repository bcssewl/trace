@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation
import os

public final class SystemAudioCapture: @unchecked Sendable {

    public struct Diagnostics: Sendable {
        public let isRunning: Bool
        public let tapID: AudioObjectID
        public let aggregateDeviceID: AudioObjectID
        public let tapFormatSampleRate: Double
        public let tapFormatChannelCount: UInt32
        public let framesObserved: Int64
        public let secondsObserved: TimeInterval
        public let zeroBufferRunSeconds: TimeInterval
        /// Sticky: true once any non-silent buffer has been delivered since the
        /// capture started. Distinguishes "tap is authorized and working" from
        /// "tap reports success but only ever yields digital silence" (the
        /// permission-not-taking-effect case on a quarantined/translocated app).
        public let hasObservedNonZeroAudio: Bool
    }

    public struct TestHooks: Sendable {
        public let watchdogThreshold: TimeInterval
        public let simulatedRunning: @Sendable () -> Bool
        /// Invoked at the start of every rebuild pass, on the control queue.
        /// Tests block here to pile up concurrent rebuild requests and prove
        /// they coalesce instead of overlapping.
        public let rebuildHold: (@Sendable () -> Void)?
        public init(
            watchdogThreshold: TimeInterval,
            simulatedRunning: @escaping @Sendable () -> Bool,
            rebuildHold: (@Sendable () -> Void)? = nil
        ) {
            self.watchdogThreshold = watchdogThreshold
            self.simulatedRunning = simulatedRunning
            self.rebuildHold = rebuildHold
        }
    }

    public let buffers: AsyncStream<AVAudioPCMBuffer>
    private let buffersContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private let onRebuildBox = OSAllocatedUnfairLock<(@Sendable () -> Void)>(initialState: {})
    private let onHealthEventBox = OSAllocatedUnfairLock<(@Sendable (CaptureHealthEvent) -> Void)?>(
        initialState: nil)

    public func setOnRebuild(_ closure: @escaping @Sendable () -> Void) {
        onRebuildBox.withLock { $0 = closure }
    }

    /// Observe capture health: watchdog/device-change recoveries and rebuild
    /// failures. `.rebuildFailed` means capture has STOPPED and the buffer
    /// stream is finished — surface it loudly, never degrade silently.
    public func setOnHealthEvent(_ closure: @escaping @Sendable (CaptureHealthEvent) -> Void) {
        onHealthEventBox.withLock { $0 = closure }
    }

    private let isRunning = SyncBool(initial: false)
    /// Sticky: set once `buffersContinuation` is finished (on stop or fatal
    /// rebuild failure). A finished stream can never deliver again, so this
    /// instance is single-use — `start()` after `stop()` throws instead of
    /// silently capturing into a dead stream.
    private let streamFinished = SyncBool(initial: false)
    private let tapIDBox = OSAllocatedUnfairLock(initialState: AudioObjectID(kAudioObjectUnknown))
    private let aggIDBox = OSAllocatedUnfairLock(initialState: AudioObjectID(kAudioObjectUnknown))
    private let ioProcIDBox = OSAllocatedUnfairLock<AudioDeviceIOProcID?>(initialState: nil)
    private let tapFormatBox = OSAllocatedUnfairLock(initialState: AudioStreamBasicDescription())
    private let framesObservedLock = OSAllocatedUnfairLock(initialState: Int64(0))
    private let secondsObservedLock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    private let lastNonZeroLock = OSAllocatedUnfairLock(initialState: Date())
    private let zeroRunLock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    /// Sticky flag set the first time a non-silent buffer is delivered. Once the
    /// tap has produced real audio we know it's genuinely authorized, so a later
    /// run of silence is just a quiet call — not a permission failure.
    private let observedNonZero = SyncBool(initial: false)

    // Accessed ONLY on `control`'s queue (start/stop/rebuild bodies), which is
    // what makes these plain vars safe on an @unchecked Sendable class.
    private var watchdogTimer: DispatchSourceTimer?
    private var deviceWatcher: DeviceWatcher?
    private var deviceWatcherTask: Task<Void, Never>?

    /// Serialises start/stop/rebuild and coalesces overlapping rebuild
    /// requests (watchdog + device watcher can fire together; the HAL must
    /// never see two concurrent tearDown/build passes).
    private let control = SerialRebuildCoordinator(label: "app.trace.audio.system-tap.control")

    /// Reuse pool for IO-proc buffers — see `AudioBufferPool`. Rebuilt to the
    /// tap format on every (re)build; consumers opt in via `recycle(_:)`.
    private let bufferPool = AudioBufferPool(maxPooledBuffers: 16)
    /// Pooled buffer capacity. HAL chunks for an aggregate tap are typically
    /// ≤2048 frames; 4096 gives headroom so acquire never misses on size.
    private static let pooledCapacityFrames: AVAudioFrameCount = 4_096

    private let ioQueue: DispatchQueue
    private let testHooks: TestHooks?

    public init(testHooks: TestHooks? = nil) {
        self.testHooks = testHooks
        self.ioQueue = DispatchQueue(
            label: "app.trace.audio.system-tap.io",
            qos: .userInteractive
        )
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.buffers = stream
        self.buffersContinuation = continuation
    }

    deinit {
        stop()
        buffersContinuation.finish()
    }

    public static func isSupported() -> Bool {
        if #available(macOS 14.4, *) {
            return true
        }
        return false
    }

    /// Best-effort: is the system's default OUTPUT device actively doing IO
    /// (i.e. some app is playing audio out of the Mac right now)?
    ///
    /// Used to tell "the other side is genuinely silent" apart from "our tap is
    /// deaf": if audio is playing out but the tap only ever delivers digital
    /// silence, the System Audio Recording permission isn't taking effect. A
    /// read-only property query — safe to call from any thread.
    public static func isDefaultOutputActive() -> Bool {
        guard let outID = try? DeviceWatcher.currentDefaultOutputDeviceID(),
            outID != kAudioObjectUnknown
        else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(outID, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    public func start() throws {
        try control.withExclusiveControl {
            guard isRunning.compareAndSwap(expected: false, desired: true) else { return }
            guard !streamFinished.value else {
                isRunning.value = false
                throw TraceError.audioCaptureFailed(
                    reason:
                        "SystemAudioCapture is single-use: its buffer stream finished when it stopped. Create a fresh instance."
                )
            }
            do {
                if testHooks == nil {
                    try buildPipelineOnQueue()
                }
                startWatchdogOnQueue()
                if testHooks == nil {
                    startDeviceWatcherOnQueue()
                }
                Loggers.audio.info("SystemAudioCapture started")
            } catch {
                isRunning.value = false
                tearDownCoreAudioResources()
                throw error
            }
        }
    }

    public func stop() {
        control.withExclusiveControl {
            guard isRunning.compareAndSwap(expected: true, desired: false) else { return }
            stopAuxiliariesOnQueue()
            tearDownCoreAudioResources()
            bufferPool.drain()
            // Finish the buffer stream: stop() means this capture will never
            // deliver again, and a finished stream is what lets consumers
            // (the meeting pipeline) drain to a clean end-of-stream instead of
            // hanging on an open-but-dead stream.
            finishStreamOnQueue()
            Loggers.audio.info("SystemAudioCapture stopped")
        }
    }

    /// Cancel watchdog + device watcher. Control-queue only.
    private func stopAuxiliariesOnQueue() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        deviceWatcher?.stop()
        deviceWatcher = nil
        deviceWatcherTask?.cancel()
        deviceWatcherTask = nil
    }

    private func finishStreamOnQueue() {
        guard streamFinished.compareAndSwap(expected: false, desired: true) else { return }
        buffersContinuation.finish()
    }

    public func diagnostics() -> Diagnostics {
        let asbd = tapFormatBox.withLock { $0 }
        return Diagnostics(
            isRunning: isRunning.value,
            tapID: tapIDBox.withLock { $0 },
            aggregateDeviceID: aggIDBox.withLock { $0 },
            tapFormatSampleRate: asbd.mSampleRate,
            tapFormatChannelCount: asbd.mChannelsPerFrame,
            framesObserved: framesObservedLock.withLock { $0 },
            secondsObserved: secondsObservedLock.withLock { $0 },
            zeroBufferRunSeconds: zeroRunLock.withLock { $0 },
            hasObservedNonZeroAudio: observedNonZero.value)
    }

    public func injectForTesting(_ buffer: AVAudioPCMBuffer) {
        ioProcDeliver(buffer)
    }

    /// Hand a buffer received from `buffers` back for reuse once you have
    /// finished reading it (copied out whatever samples you need).
    ///
    /// Optional: consumers that never recycle just leave the IO proc on its
    /// allocate-fresh fallback (the previous behaviour). Never recycle a
    /// buffer something else may still be reading — that aliases live audio.
    public func recycle(_ buffer: AVAudioPCMBuffer) {
        bufferPool.recycle(buffer)
    }

    /// Pool stats, exposed for tests/diagnostics.
    public var bufferPoolStats: AudioBufferPool.Stats {
        bufferPool.stats
    }

    /// Control-queue only.
    private func buildPipelineOnQueue() throws {
        guard Self.isSupported() else {
            throw TraceError.audioCaptureFailed(
                reason: "SystemAudioCapture requires macOS 14.4 or newer")
        }

        // For a "capture system audio" tap we want a GLOBAL tap that excludes
        // no processes — `init(monoGlobalTapButExcludeProcesses: [])`. This is
        // the only mode that triggers macOS's audio-capture TCC prompt and
        // gets the app registered in System Settings → Privacy & Security →
        // Screen & System Audio Recording → System Audio Recording Only.
        // The previous `processes: [selfPID]` failed on macOS 26 with
        // "AudioHardwareCreateProcessTap: can't find specified process object"
        // because raw PIDs aren't AudioObjectIDs.
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "Trace System Tap"
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var tapIDOut: AudioObjectID = kAudioObjectUnknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapIDOut)
        guard createStatus == noErr, tapIDOut != kAudioObjectUnknown else {
            if createStatus == kAudioHardwareIllegalOperationError {
                throw TraceError.permissionDenied(kind: .systemAudio)
            }
            throw TraceError.audioCaptureFailed(
                reason: "AudioHardwareCreateProcessTap failed: \(createStatus)")
        }
        let newTapID = tapIDOut
        tapIDBox.withLock { $0 = newTapID }

        guard
            let asbd = Self.retryOnBadObject(
                maxAttempts: 10, sleepMs: 50,
                body: {
                    Self.readTapFormat(tapID: newTapID)
                })
        else {
            throw TraceError.audioCaptureFailed(
                reason: "kAudioTapPropertyFormat unreadable after 10 retries (BadObject)")
        }
        tapFormatBox.withLock { $0 = asbd }

        // Pre-size the IO buffer reuse pool to the (possibly new) tap format so
        // the steady-state IO callback never allocates.
        var asbdForFormat = asbd
        if let avFormat = AVAudioFormat(streamDescription: &asbdForFormat) {
            bufferPool.rebuild(
                format: avFormat, capacityFrames: Self.pooledCapacityFrames, preallocate: 8)
        }

        Loggers.audio.info(
            "SystemAudioCapture tap created: rate=\(asbd.mSampleRate, privacy: .public) ch=\(asbd.mChannelsPerFrame, privacy: .public)"
        )

        let aggUID = "app.trace.system-tap-agg-\(UUID().uuidString)"
        let tapUID = tapDescription.uuid.uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Trace System Tap Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: tapUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var aggIDOut: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggIDOut)
        guard aggStatus == noErr, aggIDOut != kAudioObjectUnknown else {
            throw TraceError.audioCaptureFailed(
                reason: "AudioHardwareCreateAggregateDevice failed: \(aggStatus)")
        }
        let newAggID = aggIDOut
        aggIDBox.withLock { $0 = newAggID }

        var procIDOut: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procIDOut,
            newAggID,
            ioQueue,
            { [weak self] _, inInputData, inInputTime, _, _ in
                self?.handleIOProc(inInputData: inInputData, inInputTime: inInputTime)
            })
        guard procStatus == noErr, let procID = procIDOut else {
            throw TraceError.audioCaptureFailed(
                reason: "AudioDeviceCreateIOProcIDWithBlock failed: \(procStatus)")
        }
        ioProcIDBox.withLock { $0 = procID }

        let startStatus = AudioDeviceStart(newAggID, procID)
        if startStatus != noErr {
            throw TraceError.audioCaptureFailed(
                reason: "AudioDeviceStart failed: \(startStatus)")
        }
    }

    private func tearDownCoreAudioResources() {
        let aggID = aggIDBox.withLock { $0 }
        let procID = ioProcIDBox.withLock { $0 }
        let tapID = tapIDBox.withLock { $0 }

        if aggID != kAudioObjectUnknown, let procID {
            _ = AudioDeviceStop(aggID, procID)
            _ = AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }

        aggIDBox.withLock { $0 = kAudioObjectUnknown }
        ioProcIDBox.withLock { $0 = nil }
        tapIDBox.withLock { $0 = kAudioObjectUnknown }
    }

    private func handleIOProc(
        inInputData: UnsafePointer<AudioBufferList>,
        inInputTime: UnsafePointer<AudioTimeStamp>
    ) {
        var asbd = tapFormatBox.withLock { $0 }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let abl = inInputData.pointee
        guard abl.mNumberBuffers > 0 else { return }
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let firstBuf = withUnsafePointer(to: abl.mBuffers) { $0.pointee }
        let frameCount = AVAudioFrameCount(Int(firstBuf.mDataByteSize) / bytesPerFrame)

        // Reuse a pooled buffer when one is available (steady state once the
        // consumer recycles); otherwise fall back to a fresh allocation, sized
        // to pool capacity so it becomes poolable when recycled.
        let buf: AVAudioPCMBuffer
        if let pooled = bufferPool.acquire(frameCount: frameCount, format: format) {
            buf = pooled
        } else if let fresh = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: max(frameCount, Self.pooledCapacityFrames))
        {
            buf = fresh
        } else {
            return
        }
        buf.frameLength = frameCount

        let dst = buf.mutableAudioBufferList
        let dstCount = Int(dst.pointee.mNumberBuffers)
        let srcCount = Int(abl.mNumberBuffers)
        let bufferCount = min(dstCount, srcCount)

        withUnsafePointer(to: abl) { srcPtr in
            let srcBuffers = withUnsafePointer(to: srcPtr.pointee.mBuffers) {
                UnsafeBufferPointer(start: $0, count: srcCount)
            }
            let dstBuffers = withUnsafeMutablePointer(to: &dst.pointee.mBuffers) {
                UnsafeMutableBufferPointer(start: $0, count: dstCount)
            }
            for i in 0..<bufferCount {
                let srcBuf = srcBuffers[i]
                let dstBuf = dstBuffers[i]
                let bytes = min(Int(srcBuf.mDataByteSize), Int(dstBuf.mDataByteSize))
                if let s = srcBuf.mData, let d = dstBuf.mData {
                    memcpy(d, s, bytes)
                }
            }
        }

        ioProcDeliver(buf)
    }

    private func ioProcDeliver(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let dt = TimeInterval(frames) / max(buffer.format.sampleRate, 1)
        framesObservedLock.withLock { $0 += Int64(frames) }
        secondsObservedLock.withLock { $0 += dt }

        let rms = AudioBufferHelpers.rms(buffer)
        if rms > 0 {
            observedNonZero.value = true
            lastNonZeroLock.withLock { $0 = Date() }
            zeroRunLock.withLock { $0 = 0 }
        } else {
            zeroRunLock.withLock { $0 += dt }
        }

        buffersContinuation.yield(buffer)
    }

    /// Control-queue only.
    private func startWatchdogOnQueue() {
        let threshold = testHooks?.watchdogThreshold ?? 30.0
        let q = DispatchQueue(label: "app.trace.audio.system-tap.watchdog")
        let timer = DispatchSource.makeTimerSource(queue: q)
        let interval: DispatchTimeInterval =
            testHooks != nil
            ? .milliseconds(100)
            : .seconds(1)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick(threshold: threshold)
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func watchdogTick(threshold: TimeInterval) {
        guard isRunning.value else { return }
        // Stand down while a rebuild is queued or in flight: a tick observing
        // the silence run that *caused* the rebuild must not request another.
        guard !control.isRebuildPendingOrActive else { return }
        let zeroRun = zeroRunLock.withLock { $0 }
        guard zeroRun >= threshold else { return }

        let osSaysRunning = testHooks?.simulatedRunning() ?? deviceIsRunningSomewhere()
        guard osSaysRunning else { return }

        Loggers.audio.error(
            "SystemAudioCapture all-zero watchdog fired: zeroRun=\(zeroRun, privacy: .public)s threshold=\(threshold, privacy: .public)s. Rebuilding."
        )
        zeroRunLock.withLock { $0 = 0 }
        requestRebuild(
            reason: "all-zero watchdog (\(Int(zeroRun))s silent)",
            trigger: .watchdogTriggeredRebuild(silentSeconds: zeroRun))
    }

    private func deviceIsRunningSomewhere() -> Bool {
        let aggID = aggIDBox.withLock { $0 }
        guard aggID != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(aggID, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    /// Control-queue only.
    private func startDeviceWatcherOnQueue() {
        let watcher = DeviceWatcher()
        do {
            try watcher.start()
        } catch {
            Loggers.audio.warning(
                "SystemAudioCapture: DeviceWatcher.start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        deviceWatcher = watcher
        let eventStream = watcher.events
        deviceWatcherTask = Task { [weak self] in
            for await event in eventStream {
                guard let self else { return }
                if case .defaultOutputChanged(let deviceID) = event {
                    let name = (try? DeviceWatcher.deviceName(for: deviceID)) ?? "unknown"
                    Loggers.audio.info(
                        "SystemAudioCapture: default output changed to \(name, privacy: .public) (id=\(deviceID, privacy: .public)); rebuilding tap"
                    )
                    self.requestRebuild(
                        reason: "default output changed to \(name)",
                        trigger: .deviceChangeTriggeredRebuild)
                }
            }
        }
    }

    /// Request a pipeline rebuild. Serialised on the control queue; overlapping
    /// requests coalesce to at most one trailing rebuild. Safe from any thread.
    ///
    /// Internal (not private) so tests can drive the coalescing logic directly.
    internal func requestRebuild(reason: String, trigger: CaptureHealthEvent? = nil) {
        let scheduled = control.requestRebuild { [weak self] in
            self?.performRebuildOnQueue()
        }
        if scheduled, let trigger {
            emitHealth(trigger)
        } else if !scheduled {
            Loggers.audio.info(
                "SystemAudioCapture rebuild request coalesced (\(reason, privacy: .public))")
        }
    }

    /// Control-queue only — invoked solely via `control.requestRebuild`.
    private func performRebuildOnQueue() {
        guard isRunning.value else { return }
        testHooks?.rebuildHold?()
        tearDownCoreAudioResources()
        do {
            if testHooks == nil {
                try buildPipelineOnQueue()
            }
            zeroRunLock.withLock { $0 = 0 }
            let cb = onRebuildBox.withLock { $0 }
            cb()
            emitHealth(.rebuildSucceeded)
            Loggers.audio.info("SystemAudioCapture rebuilt; capture resumed")
        } catch {
            Loggers.audio.error(
                "SystemAudioCapture rebuild failed: \(error.localizedDescription, privacy: .public)")
            isRunning.value = false
            stopAuxiliariesOnQueue()
            bufferPool.drain()
            finishStreamOnQueue()
            // Loud failure: capture is dead and the stream is finished. The
            // health event is what lets the runtime tell the user instead of
            // silently recording one side of the meeting.
            emitHealth(.rebuildFailed(reason: error.localizedDescription))
        }
    }

    private func emitHealth(_ event: CaptureHealthEvent) {
        (onHealthEventBox.withLock { $0 })?(event)
    }

    internal static func retryOnBadObject<T>(
        maxAttempts: Int,
        sleepMs: Int,
        body: () -> T?
    ) -> T? {
        for attempt in 0..<maxAttempts {
            if let result = body() {
                return result
            }
            if attempt < maxAttempts - 1 {
                Thread.sleep(forTimeInterval: TimeInterval(sleepMs) / 1_000)
            }
        }
        return nil
    }

    private static func readTapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        if status == kAudioHardwareBadObjectError {
            return nil
        }
        if status != noErr {
            Loggers.audio.warning(
                "readTapFormat OSStatus=\(status, privacy: .public) for tapID=\(tapID, privacy: .public)")
            return nil
        }
        return asbd
    }
}
