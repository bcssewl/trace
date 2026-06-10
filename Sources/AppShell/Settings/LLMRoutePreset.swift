import Foundation

/// A one-tap routing preset for the LLM Router — applies a whole provider set
/// across every `LLMRouteStage` (BAS-6 / BAS-35).
///
/// "Custom" is not a case: it is
/// the *absence* of a match, surfaced by `AppStateModel.activeRoutePreset`.
public enum LLMRoutePreset: String, Sendable, CaseIterable, Identifiable {
    case localFirst
    case balanced
    case cloudHeavy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localFirst: return "On your Mac"
        case .balanced: return "Balanced"
        case .cloudHeavy: return "Cloud"
        }
    }

    public var detail: String {
        switch self {
        case .localFirst: return "Everything runs on your Mac — free, private, and works offline."
        case .balanced:
            return
                "Your Mac handles the quick everyday tasks; the cloud handles notes, library answers, and coach tips."
        case .cloudHeavy: return "Use the cloud (OpenRouter) for everything — the best quality. Needs a key."
        }
    }

    /// The provider this preset assigns to `stage`.
    ///
    /// Local-first mirrors the
    /// shipped defaults exactly, so a fresh install reads as "Local-first"
    /// rather than "Custom". Note the meeting coach stage is cloud-only by
    /// design (its default IS OpenRouter), so even "On your Mac" leaves it on
    /// the cloud — the coach simply doesn't run on local models, and it is
    /// opt-in/off by default anyway.
    public func provider(for stage: LLMRouteStage) -> DictationCleanupProvider {
        switch self {
        case .localFirst:
            return stage.defaultProvider
        case .balanced:
            switch stage {
            case .meetingNotes, .libraryQA, .coachCardContent: return .openRouter
            default: return .appleFM
            }
        case .cloudHeavy:
            return .openRouter
        }
    }
}
