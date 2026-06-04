import Foundation

/// The language the user wants speech-to-text to transcribe in (BAS-74).
///
/// `.auto` lets the engine detect the language (Whisper) or falls back to the
/// system locale for engines that need an explicit one (Apple Speech / cloud);
/// every other case forces a specific language so e.g. a Mandarin meeting is
/// decoded as Chinese instead of mangled English. Threaded from Settings through
/// the runtimes to `TranscriptionBackend.transcribe(_:locale:previousContext:)`.
public enum TranscriptionLanguage: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case auto
    case english = "en"
    case mandarin = "zh"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case korean = "ko"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .mandarin: return "Chinese (Mandarin)"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        }
    }

    /// The `Locale` handed to the ASR backend. `.auto` uses the auto-detect
    /// sentinel; the rest map to a concrete language locale.
    public var locale: Locale {
        self == .auto ? .autoDetect : Locale(identifier: rawValue)
    }
}

extension Locale {
    /// Sentinel meaning "let the engine auto-detect the language" — uses the
    /// BCP-47 "undetermined" code `und` so it round-trips through `Locale`
    /// normalization cleanly (BAS-74).
    ///
    /// Whisper treats it as detect; engines that
    /// require a concrete language fall back to the system locale.
    public static let autoDetect = Locale(identifier: "und")

    /// Whether this is the auto-detect sentinel (`und`).
    public var isAutoDetect: Bool { language.languageCode?.identifier == "und" }

    /// A concrete locale a backend can use directly — auto-detect resolves to the
    /// current system locale (for engines that can't auto-detect).
    public var concreteOrCurrent: Locale { isAutoDetect ? .current : self }
}
