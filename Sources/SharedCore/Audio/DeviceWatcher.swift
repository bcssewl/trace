@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation
import os

public final class DeviceWatcher: @unchecked Sendable {

    public enum Event: Sendable, Equatable {
        case defaultInputChanged(deviceID: AudioObjectID)
        case defaultOutputChanged(deviceID: AudioObjectID)
    }

    public let events: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation
    private let isRunning = SyncBool(initial: false)

    private var inputListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = stream
        self.eventsContinuation = continuation
    }

    deinit {
        stop()
        eventsContinuation.finish()
    }

    public func start() throws {
        guard isRunning.compareAndSwap(expected: false, desired: true) else { return }

        let cont = eventsContinuation
        let inputBlock: AudioObjectPropertyListenerBlock = { _, _ in
            if let id = try? Self.currentDefaultInputDeviceID() {
                cont.yield(.defaultInputChanged(deviceID: id))
            }
        }
        let outputBlock: AudioObjectPropertyListenerBlock = { _, _ in
            if let id = try? Self.currentDefaultOutputDeviceID() {
                cont.yield(.defaultOutputChanged(deviceID: id))
            }
        }
        self.inputListener = inputBlock
        self.outputListener = outputBlock

        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let inStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddr, nil, inputBlock)
        let outStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddr, nil, outputBlock)

        guard inStatus == noErr, outStatus == noErr else {
            isRunning.value = false
            throw TraceError.audioCaptureFailed(
                reason: "DeviceWatcher AddPropertyListenerBlock failed: in=\(inStatus) out=\(outStatus)")
        }

        Loggers.audio.info("DeviceWatcher started")
    }

    public func stop() {
        guard isRunning.compareAndSwap(expected: true, desired: false) else { return }

        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        if let inBlock = inputListener {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddr, nil, inBlock)
            self.inputListener = nil
        }
        if let outBlock = outputListener {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &outputAddr, nil, outBlock)
            self.outputListener = nil
        }

        Loggers.audio.info("DeviceWatcher stopped")
    }

    public static func currentDefaultInputDeviceID() throws -> AudioObjectID {
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr else {
            throw TraceError.audioCaptureFailed(
                reason: "DeviceWatcher.currentDefaultInputDeviceID failed: \(status)")
        }
        return id
    }

    public static func currentDefaultOutputDeviceID() throws -> AudioObjectID {
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr else {
            throw TraceError.audioCaptureFailed(
                reason: "DeviceWatcher.currentDefaultOutputDeviceID failed: \(status)")
        }
        return id
    }

    public static func deviceName(for id: AudioObjectID) throws -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else {
            throw TraceError.audioCaptureFailed(
                reason: "deviceName lookup failed for id \(id): \(status)")
        }
        return cf as String
    }
}
