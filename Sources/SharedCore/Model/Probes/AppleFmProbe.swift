import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct AppleFmProbeResult: Sendable, Hashable {
    public let available: Bool
    public let reason: String?

    public init(available: Bool, reason: String?) {
        self.available = available
        self.reason = reason
    }
}

public enum AppleFmProbe {
    public static func probe() -> AppleFmProbeResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return AppleFmProbeResult(available: true, reason: nil)
            case .unavailable(let reason):
                return AppleFmProbeResult(available: false, reason: humanReason(for: reason))
            }
        }
        return AppleFmProbeResult(available: false, reason: "Requires macOS 26 or later.")
        #else
        return AppleFmProbeResult(
            available: false,
            reason: "FoundationModels framework not linked in this build."
        )
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func humanReason(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Enable it in System Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple Intelligence model is still downloading. Try again in a few minutes."
        @unknown default:
            return "Unavailable: \(String(describing: reason))"
        }
    }
    #endif
}
