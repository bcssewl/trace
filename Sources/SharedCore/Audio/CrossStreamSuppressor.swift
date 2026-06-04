@preconcurrency import CoreAudio
import Foundation

/// Describes where the system's default audio output is currently routed.
///
/// Used by meeting capture to decide whether acoustic echo cancellation (AEC)
/// is needed: when the user listens on laptop **speakers**, remote voices leak
/// into the mic and should be suppressed; on **headphones** there is no acoustic
/// path back into the mic, so AEC can be disabled.
public enum AudioOutputRoute: Sendable {
    case headphones
    case speakers
    case unknown

    /// Reads the system default output device's transport type via CoreAudio and
    /// maps it to a coarse route.
    ///
    /// Never throws; returns `.unknown` on any error.
    ///
    /// - `kAudioDeviceTransportTypeBuiltIn` → `.speakers`
    /// - bluetooth / bluetoothLE / usb / displayPort / airPlay / thunderbolt / HDMI → `.headphones`
    /// - everything else (incl. unknown / failure) → `.unknown`
    public static func current() -> AudioOutputRoute {
        guard let deviceID = defaultOutputDeviceID(), deviceID != kAudioObjectUnknown else {
            return .unknown
        }
        guard let transport = transportType(for: deviceID) else {
            return .unknown
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .speakers
        case kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeHDMI:
            return .headphones
        default:
            return .unknown
        }
    }

    /// True only for `.speakers` — the only route where mic echo of the remote
    /// stream is physically possible and AEC is worth running.
    public var recommendsAEC: Bool {
        self == .speakers
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr else { return nil }
        return id
    }

    private static func transportType(for deviceID: AudioObjectID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport
    }
}

/// Live, text-domain echo suppressor for meeting capture.
///
/// When the user is on laptop speakers, remote voices (the system-audio stream)
/// leak back into the microphone and get transcribed twice — once correctly as a
/// remote speaker, and once mislabeled as "you" on the mic stream. This actor
/// retains a short rolling window of recent **system** utterances and lets the
/// runtime ask, for each fresh **mic** utterance, whether it is an echo that
/// should be dropped.
///
/// Matching is purely lexical (no audio): an utterance is an echo when its
/// normalized word set has high Jaccard overlap with — or is contained in — a
/// recent system utterance within the time window.
public actor CrossStreamSuppressor {

    private struct Entry {
        let words: Set<String>
        let t: Double
    }

    private let jaccardThreshold: Double
    private let windowSeconds: Double
    private let maxRetained: Int

    private var entries: [Entry] = []

    /// - Parameters:
    ///   - jaccardThreshold: minimum Jaccard similarity (0...1) to call a match.
    ///   - windowSeconds: max |t_mic - t_sys| for a system utterance to be a candidate.
    ///   - maxRetained: hard cap on retained system utterances (oldest dropped first).
    public init(jaccardThreshold: Double = 0.78, windowSeconds: Double = 1.75, maxRetained: Int = 64) {
        self.jaccardThreshold = jaccardThreshold
        self.windowSeconds = windowSeconds
        self.maxRetained = max(1, maxRetained)
    }

    /// Record a system-audio (remote speaker) utterance at time `t` (seconds).
    ///
    /// Evicts entries older than `windowSeconds` relative to the newest `t`, then
    /// caps the buffer to `maxRetained` by dropping the oldest.
    public func noteSystemUtterance(text: String, at t: Double) {
        let words = Self.normalize(text)
        guard !words.isEmpty else { return }
        entries.append(Entry(words: words, t: t))
        prune(newest: t)
    }

    /// Returns `true` if `text` (a mic utterance at time `t`) appears to be an
    /// echo of a recently-noted system utterance within the time window.
    ///
    /// A candidate within `windowSeconds` matches when either:
    /// - `Jaccard(mic, sys) >= jaccardThreshold`, or
    /// - containment: the smaller word set is a subset of the larger AND the
    ///   smaller set has `>= 3` words.
    ///
    /// Mic text with fewer than 2 words is never treated as an echo.
    public func isMicEcho(text: String, at t: Double) -> Bool {
        let micWords = Self.normalize(text)
        guard micWords.count >= 2 else { return false }

        for entry in entries {
            guard abs(t - entry.t) <= windowSeconds else { continue }
            let sysWords = entry.words
            if Self.jaccard(micWords, sysWords) >= jaccardThreshold {
                return true
            }
            let smaller = micWords.count <= sysWords.count ? micWords : sysWords
            let larger = micWords.count <= sysWords.count ? sysWords : micWords
            if smaller.count >= 3, smaller.isSubset(of: larger) {
                return true
            }
        }
        return false
    }

    /// Clears all retained system utterances (e.g. on meeting stop / restart).
    public func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    private func prune(newest: Double) {
        entries.removeAll { newest - $0.t > windowSeconds }
        if entries.count > maxRetained {
            // entries are appended in arrival order; oldest are at the front.
            entries.removeFirst(entries.count - maxRetained)
        }
    }

    // MARK: - Pure helpers (deterministic, testable)

    /// Lowercase, strip punctuation, collapse whitespace, return the set of words.
    static func normalize(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        let cleaned = String(scalars)
        let words = cleaned.split(whereSeparator: { $0 == " " }).map(String.init)
        return Set(words)
    }

    /// Jaccard similarity |A ∩ B| / |A ∪ B|.
    ///
    /// Empty/empty → 0.
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        let intersection = a.intersection(b).count
        let union = a.count + b.count - intersection
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
