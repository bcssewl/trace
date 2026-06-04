import AppKit
import Foundation

public enum ModifierTapKey: String, Sendable, Hashable, Codable, CaseIterable {
    case rightOption
    case rightCommand
    case rightControl

    /// The virtual key code macOS reports for this physical key.
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    /// Device-dependent modifier-flag mask, used to tell a key *down* from a
    /// key *up* on a `flagsChanged` event (the device-independent flags can't
    /// distinguish left from right, these can).
    public var deviceFlagMask: UInt {
        switch self {
        case .rightOption: return 0x0040  // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x0010  // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x2000  // NX_DEVICERCTLKEYMASK
        }
    }

    /// Human-readable label, e.g. "Right ⌘".
    public var displayName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        }
    }

    /// Maps a raw key code back to a known right-side modifier, if any.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 61: self = .rightOption
        case 54: self = .rightCommand
        case 62: self = .rightControl
        default: return nil
        }
    }

    /// The right-side modifier being *pressed down* in this `flagsChanged`
    /// event, or `nil` for a key-up or any non–right-modifier key.
    public static func pressed(in event: NSEvent) -> ModifierTapKey? {
        guard let key = ModifierTapKey(keyCode: event.keyCode), key.isDown(in: event) else { return nil }
        return key
    }

    /// Whether this specific key is held down in the given `flagsChanged` event.
    public func isDown(in event: NSEvent) -> Bool {
        event.keyCode == keyCode && (event.modifierFlags.rawValue & deviceFlagMask) != 0
    }
}

public struct ModifierTapEvent: Sendable, Hashable {
    public let key: ModifierTapKey
    public let timestamp: TimeInterval
    public let isDown: Bool
    public init(key: ModifierTapKey, timestamp: TimeInterval, isDown: Bool) {
        self.key = key
        self.timestamp = timestamp
        self.isDown = isDown
    }
}

public struct TripleTapDetector: Sendable {
    private let key: ModifierTapKey
    private let tapCount: Int
    private let window: TimeInterval
    private var taps: [TimeInterval] = []
    private var armed = true

    public init(key: ModifierTapKey = .rightOption, tapCount: Int = 3, window: TimeInterval = 0.5) {
        self.key = key
        self.tapCount = tapCount
        self.window = window
    }

    public mutating func ingest(_ event: ModifierTapEvent) -> Bool {
        guard event.key == key, event.isDown else { return false }
        taps.append(event.timestamp)
        taps = taps.filter { event.timestamp - $0 <= window }
        guard taps.count >= tapCount, armed else { return false }
        armed = false
        taps.removeAll(keepingCapacity: true)
        return true
    }

    public mutating func resetArming() {
        armed = true
    }
}

@MainActor
public final class TripleTapMonitor {
    private var monitor: Any?
    private var detector: TripleTapDetector
    private let onFire: @Sendable () -> Void

    public init(detector: TripleTapDetector = TripleTapDetector(), onFire: @escaping @Sendable () -> Void) {
        self.detector = detector
        self.onFire = onFire
    }

    public func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let tap = ModifierTapEvent(event: event) else { return }
            if self.detector.ingest(tap) {
                self.onFire()
            }
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension ModifierTapEvent {
    fileprivate init?(event: NSEvent) {
        guard let key = ModifierTapKey(keyCode: event.keyCode) else { return nil }
        self.init(key: key, timestamp: event.timestamp, isDown: true)
    }
}

/// Watches a single right-side modifier key (e.g. right ⌘) and reports its press
/// and release edges, so a lone key can drive a tap-or-hold dictation trigger.
///
/// Uses both a global monitor (fires while other apps are focused — the usual
/// dictation case) and a local monitor (fires while our own app is focused). It
/// reports the raw edges; the caller decides tap-vs-hold from the `held` duration
/// passed to `onUp` (quick tap → toggle, long hold → push-to-talk). The `isDown`
/// guard debounces, so each physical press yields exactly one down/up pair.
@MainActor
public final class ModifierTriggerMonitor {
    private let key: ModifierTapKey
    private let onDown: @Sendable () -> Void
    private let onUp: @Sendable (TimeInterval) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var downTimestamp: TimeInterval = 0

    public init(
        key: ModifierTapKey,
        onDown: @escaping @Sendable () -> Void,
        onUp: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.key = key
        self.onDown = onDown
        self.onUp = onUp
    }

    public func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == key.keyCode else { return }
        let down = key.isDown(in: event)
        if down, !isDown {
            isDown = true
            downTimestamp = event.timestamp
            onDown()
        } else if !down, isDown {
            isDown = false
            onUp(event.timestamp - downTimestamp)
        }
    }
}
