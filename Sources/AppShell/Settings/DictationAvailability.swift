import Foundation
import SharedCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Snapshot of what's actually usable on this machine right now.
///
/// Surfaced in
/// Settings → Dictation models and Settings → AI models so the picker rows can
/// show status like "not downloaded" / "Ollama not running" / "needs a key"
/// instead of silently letting the user pick something that will fail.
public struct DictationAvailability: Sendable, Equatable {
    public var parakeetCached: Bool = false
    public var appleFM: Bool = false
    public var ollamaReachable: Bool = false
    public var openRouterKeySet: Bool = false
    /// On-device WhisperKit / Qwen3 readiness (BAS-8).
    ///
    /// Reflect each backend's
    /// real `checkStatus()`, so the engine becomes selectable only once its
    /// integration + model are actually present (today both are pending).
    public var whisperKitReady: Bool = false
    public var qwen3Ready: Bool = false

    public static let unknown = DictationAvailability()

    /// Whether the on-device model backing `engine` is downloaded/ready to use.
    ///
    /// Only the engines that ship a downloadable model report readiness here;
    /// engines with no model to fetch (Apple Speech, cloud) and the nil case
    /// report `false` and are gated by the caller's `needsDownload` flag instead.
    /// Centralizes the per-engine readiness lookup so adding a downloadable
    /// engine touches one switch, not an OR-chain at every call site (BAS-8).
    public func modelReady(for engine: DictationASREngine?) -> Bool {
        switch engine {
        case .parakeet: return parakeetCached
        case .whisperKit: return whisperKitReady
        case .qwen3: return qwen3Ready
        case .appleSpeech, .cloud, .none: return false
        }
    }
}

@MainActor
public final class DictationAvailabilityProbe {
    private let session: URLSession
    private let keychain: KeychainSecrets
    private let ollamaURL: URL
    /// Where FluidAudio caches its CoreML weights.
    ///
    /// If the directory exists +
    /// is non-empty, we assume Parakeet is ready (don't re-download).
    private let fluidAudioCache: URL

    public init(
        session: URLSession = .shared,
        keychain: KeychainSecrets = KeychainSecrets(),
        ollamaURL: URL = URL(string: "http://localhost:11434/api/tags")!
    ) {
        self.session = session
        self.keychain = keychain
        self.ollamaURL = ollamaURL
        let fm = FileManager.default
        let support =
            (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fluidAudioCache =
            support
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public func probe() async -> DictationAvailability {
        async let parakeet = checkParakeet()
        async let appleFM = checkAppleFM()
        async let ollama = checkOllama()
        async let openRouter = checkOpenRouterKey()
        async let whisperKit = checkBackendReady(WhisperKitBackend())
        async let qwen3 = checkBackendReady(Qwen3Backend())
        return await DictationAvailability(
            parakeetCached: parakeet,
            appleFM: appleFM,
            ollamaReachable: ollama,
            openRouterKeySet: openRouter,
            whisperKitReady: whisperKit,
            qwen3Ready: qwen3
        )
    }

    /// A backend is "ready" for selection when it reports `.ready`/`.loaded`
    /// rather than `.unavailable`/`.notDownloaded` (BAS-8).
    private func checkBackendReady(_ backend: any TranscriptionBackend) async -> Bool {
        switch await backend.checkStatus() {
        case .ready, .loaded: return true
        case .unavailable, .notDownloaded, .downloading: return false
        }
    }

    private func checkParakeet() async -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: fluidAudioCache.path) else { return false }
        return !contents.isEmpty
    }

    private func checkAppleFM() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private func checkOllama() async -> Bool {
        var req = URLRequest(url: ollamaURL)
        req.timeoutInterval = 1.2
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func checkOpenRouterKey() async -> Bool {
        guard let value = try? keychain.load(account: "openrouter") else { return false }
        return !value.isEmpty
    }
}
