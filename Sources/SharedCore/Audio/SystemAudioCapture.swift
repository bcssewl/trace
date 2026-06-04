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
    }

    public struct TestHooks: Sendable {
        public let watchdogThreshold: TimeInterval
        public let simulatedRunning: @Sendable () -> Bool
        public init(watchdogThreshold: TimeInterval, simulatedRunning: @escaping @Sendable () -> Bool) {
            self.watchdogThreshold = watchdogThreshold
            self.simulatedRunning = simulatedRunning
        }
    }

    public let buffers: AsyncStream<AVAudioPCMBuffer>
    private let buffersContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private let onRebuildBox = OSAllocatedUnfairLock<(@Sendable () -> Void)>(initialState: {})

    public func setOnRebuild(_ closure: @escaping @Sendable () -> Void) {
        onRebuildBox.withLock { $0 = closure }
    }

    private let isRunning = SyncBool(initial: false)
    private let tapIDBox = OSAllocatedUnfairLock(initialState: AudioObjectID(kAudioObjectUnknown))
    private let aggIDBox = OSAllocatedUnfairLock(initialState: AudioObjectID(kAudioObjectUnknown))
    private let ioProcIDBox = OSAllocatedUnfairLock<AudioDeviceIOProcID?>(initialState: nil)
    private let tapFormatBox = OSAllocatedUnfairLock(initialState: AudioStreamBasicDescription())
    private let framesObservedLock = OSAllocatedUnfairLock(initialState: Int64(0))
    private let secondsObservedLock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    private let lastNonZeroLock = OSAllocatedUnfairLock(initialState: Date())
    private let zeroRunLock = OSAllocatedUnfairLock(initialState: TimeInterval(0))

    private var watchdogTimer: DispatchSourceTimer?
    private var deviceWatcher: DeviceWatcher?
    private var deviceWatcherTask: Task<Void, Never>?
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

    public func start() throws {
        guard isRunning.compareAndSwap(expected: false, desired: true) else { return }
        do {
            try buildPipeline()
            startWatchdog()
            startDeviceWatcher()
            Loggers.audio.info("SystemAudioCapture started")
        } catch {
            isRunning.value = false
            tearDownCoreAudioResources()
            throw error
        }
    }

    public func stop() {
        guard isRunning.compareAndSwap(expected: true, desired: false) else { return }
        watchdogTimer?.cancel()
        watchdogTimer = nil
        deviceWatcher?.stop()
        deviceWatcher = nil
        deviceWatcherTask?.cancel()
        deviceWatcherTask = nil
        tearDownCoreAudioResources()
        Loggers.audio.info("SystemAudioCapture stopped")
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
            zeroBufferRunSeconds: zeroRunLock.withLock { $0 })
    }

    public func injectForTesting(_ buffer: AVAudioPCMBuffer) {
        ioProcDeliver(buffer)
    }

    private func buildPipeline() throws {
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

        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
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
            lastNonZeroLock.withLock { $0 = Date() }
            zeroRunLock.withLock { $0 = 0 }
        } else {
            zeroRunLock.withLock { $0 += dt }
        }

        buffersContinuation.yield(buffer)
    }

    private func startWatchdog() {
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
        let zeroRun = zeroRunLock.withLock { $0 }
        guard zeroRun >= threshold else { return }

        let osSaysRunning = testHooks?.simulatedRunning() ?? deviceIsRunningSomewhere()
        guard osSaysRunning else { return }

        Loggers.audio.error(
            "SystemAudioCapture all-zero watchdog fired: zeroRun=\(zeroRun, privacy: .public)s threshold=\(threshold, privacy: .public)s. Rebuilding."
        )
        zeroRunLock.withLock { $0 = 0 }
        rebuild()
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

    private func startDeviceWatcher() {
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
                if case .defaultOutputChanged = event {
                    Loggers.audio.info(
                        "SystemAudioCapture: default output changed; rebuilding tap")
                    self.rebuild()
                }
            }
        }
    }

    private func rebuild() {
        guard isRunning.value else { return }
        tearDownCoreAudioResources()
        do {
            if testHooks == nil {
                try buildPipeline()
            }
            zeroRunLock.withLock { $0 = 0 }
            let cb = onRebuildBox.withLock { $0 }
            cb()
        } catch {
            Loggers.audio.error(
                "SystemAudioCapture rebuild failed: \(error.localizedDescription, privacy: .public)")
            isRunning.value = false
            buffersContinuation.finish()
        }
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
