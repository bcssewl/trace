import Foundation

/// Maps a resolved `ASRRoute` to a concrete, un-prepared `TranscriptionBackend`.
///
/// This is the single construction point for every ASR engine — local and cloud.
/// It used to live privately inside `RuntimeASRBackendResolver` and only built
/// the local engines, so cloud routes (`groq`, `volcengine`, …) silently fell
/// through to `nil` and the resolver dropped to Apple Speech — cloud
/// transcription could never actually run (BAS-21). Pulling it out here makes the
/// mapping pure and unit-testable, and the resolver keeps its own instance cache
/// on top.
///
/// Cloud engines are only built when the route explicitly `allowsCloud`; a cloud
/// provider identifier on a local-only route returns `nil` (the
/// sensitive/local-only guard), so the resolver falls back rather than leaking
/// audio to a network service.
public enum ASRBackendFactory {
    public static func makeBackend(for route: ASRRoute) -> (any TranscriptionBackend)? {
        switch route.engineIdentifier {
        case "parakeet":
            return ParakeetBackend()
        case "whisperkit":
            return WhisperKitBackend()
        case "qwen3":
            return Qwen3Backend()
        case "apple-speech":
            return AppleSpeechBackend()
        default:
            guard let provider = CloudASRProvider(rawValue: route.engineIdentifier),
                route.allowsCloud
            else {
                return nil
            }
            return CloudASRBackend(provider: provider)
        }
    }
}
