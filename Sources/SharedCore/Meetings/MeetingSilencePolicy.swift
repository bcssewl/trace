import Foundation

/// Decides what to do after a stretch of meeting silence (BAS-13), from how long
/// it's been since any captured speech (VAD on either stream — never device-in-use
/// flags, which stay true the whole meeting because we hold the mic).
///
/// Two thresholds, evaluated together: the existing soft "Call ended?" notch
/// prompt fires once at `softThreshold`; a separate, longer `hardThreshold`
/// (default 10 min, user-configurable, gated on auto-detect) hard-stops + finalizes
/// the meeting so a call that's truly over still summarizes. The hard stop takes
/// priority; a nil `hardThreshold` disables it (hard auto-stop off).
public enum MeetingSilencePolicy {

    public enum Action: Equatable, Sendable {
        case none
        case promptSoftEnd
        case hardStop
    }

    public static func evaluate(
        secondsSinceSpeech: TimeInterval,
        softThreshold: TimeInterval,
        hardThreshold: TimeInterval?,
        alreadyPrompted: Bool
    ) -> Action {
        if let hardThreshold, secondsSinceSpeech >= hardThreshold {
            return .hardStop
        }
        if !alreadyPrompted, secondsSinceSpeech >= softThreshold {
            return .promptSoftEnd
        }
        return .none
    }
}
