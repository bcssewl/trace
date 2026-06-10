import Foundation

/// Snapshot of the default routing + Sparkle + storage configuration that the
/// app installs into the `settings_kv` table on first launch.
///
/// This is the
/// runtime mirror of `Resources/BootstrapConfig.json` shipped inside the
/// `.app` bundle. The Swift defaults defined here are the *source of truth*
/// for tests and for builds that omit the JSON file; the JSON file is only
/// consulted at launch time to allow operator overrides without rebuilding.
public struct BootstrapConfig: Sendable, Codable, Hashable {

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let llmRoutes: [LLMTaskClass: LLMRoute]
    public let embeddingRoutes: [EmbeddingTaskClass: EmbeddingRoute]
    public let hotkeys: HotkeyDefaults
    public let sparkle: SparkleDefaults
    public let storage: StorageDefaults
    public let modelCaches: ModelCacheLocations
    public let diagnostics: DiagnosticsDefaults

    public init(
        schemaVersion: Int = BootstrapConfig.currentSchemaVersion,
        llmRoutes: [LLMTaskClass: LLMRoute],
        embeddingRoutes: [EmbeddingTaskClass: EmbeddingRoute],
        hotkeys: HotkeyDefaults,
        sparkle: SparkleDefaults,
        storage: StorageDefaults,
        modelCaches: ModelCacheLocations,
        diagnostics: DiagnosticsDefaults
    ) {
        self.schemaVersion = schemaVersion
        self.llmRoutes = llmRoutes
        self.embeddingRoutes = embeddingRoutes
        self.hotkeys = hotkeys
        self.sparkle = sparkle
        self.storage = storage
        self.modelCaches = modelCaches
        self.diagnostics = diagnostics
    }

    public struct HotkeyDefaults: Sendable, Codable, Hashable {
        public let dictationPushToTalk: HotkeyBinding
        public let manualCoachTrigger: HotkeyBinding
        public let openMainWindow: HotkeyBinding
        public let globalSearchQA: HotkeyBinding

        public init(
            dictationPushToTalk: HotkeyBinding,
            manualCoachTrigger: HotkeyBinding,
            openMainWindow: HotkeyBinding,
            globalSearchQA: HotkeyBinding
        ) {
            self.dictationPushToTalk = dictationPushToTalk
            self.manualCoachTrigger = manualCoachTrigger
            self.openMainWindow = openMainWindow
            self.globalSearchQA = globalSearchQA
        }
    }

    public struct HotkeyBinding: Sendable, Codable, Hashable {
        public let key: String
        public let modifiers: [String]
        public let tripleTap: Bool

        public init(key: String, modifiers: [String], tripleTap: Bool) {
            self.key = key
            self.modifiers = modifiers
            self.tripleTap = tripleTap
        }
    }

    public struct SparkleDefaults: Sendable, Codable, Hashable {
        public let feedURL: String
        public let publicEDKey: String
        public let enableAutomaticChecks: Bool
        public let scheduledCheckIntervalSeconds: Int

        public init(
            feedURL: String,
            publicEDKey: String,
            enableAutomaticChecks: Bool,
            scheduledCheckIntervalSeconds: Int
        ) {
            self.feedURL = feedURL
            self.publicEDKey = publicEDKey
            self.enableAutomaticChecks = enableAutomaticChecks
            self.scheduledCheckIntervalSeconds = scheduledCheckIntervalSeconds
        }
    }

    public struct StorageDefaults: Sendable, Codable, Hashable {
        public let markdownRoot: String
        public let sqlitePath: String

        public init(markdownRoot: String, sqlitePath: String) {
            self.markdownRoot = markdownRoot
            self.sqlitePath = sqlitePath
        }
    }

    public struct ModelCacheLocations: Sendable, Codable, Hashable {
        public let fluidAudio: String
        public let whisperKit: String
        public let mlxModels: String

        public init(fluidAudio: String, whisperKit: String, mlxModels: String) {
            self.fluidAudio = fluidAudio
            self.whisperKit = whisperKit
            self.mlxModels = mlxModels
        }
    }

    public struct DiagnosticsDefaults: Sendable, Codable, Hashable {
        public let logRetentionDays: Int
        public let exportAllowed: Bool

        public init(logRetentionDays: Int, exportAllowed: Bool) {
            self.logRetentionDays = logRetentionDays
            self.exportAllowed = exportAllowed
        }
    }

    /// Hard-coded default mirror of `Resources/BootstrapConfig.json`.
    ///
    /// Kept here
    /// so a release build without the resource (i.e. unit tests) still
    /// produces a coherent route table.
    public static let bundled: BootstrapConfig = .init(
        llmRoutes: defaultLLMRoutes,
        embeddingRoutes: defaultEmbeddingRoutes,
        hotkeys: defaultHotkeys,
        sparkle: defaultSparkle,
        storage: defaultStorage,
        modelCaches: defaultModelCaches,
        diagnostics: defaultDiagnostics
    )

    // MARK: - Defaults (mirror spec §4.3, §10, §15)

    private static let defaultLLMRoutes: [LLMTaskClass: LLMRoute] = [
        .dictationCleanup: LLMRoute(provider: .appleFM, model: "FoundationModels"),
        .titleGeneration: LLMRoute(provider: .appleFM, model: "FoundationModels"),
        .projectCategorization: LLMRoute(provider: .appleFM, model: "FoundationModels"),
        .meetingSummary: LLMRoute(
            provider: .openAICompat,
            model: "openai/gpt-5",
            baseURL: URL(string: "https://openrouter.ai/api/v1"),
            keychainAccount: "openrouter"
        ),
        .meetingAugmentedMerge: LLMRoute(
            provider: .openAICompat,
            model: "openai/gpt-5",
            baseURL: URL(string: "https://openrouter.ai/api/v1"),
            keychainAccount: "openrouter"
        ),
        // Retired task class (the old coach gatekeeper pipeline); kept only so
        // persisted route tables that still mention it decode.
        .coachSmartRouting: LLMRoute(provider: .appleFM, model: "FoundationModels"),
        // The coach is cloud-only by design. Flash Lite by the owner's cost
        // call (bench: 9/10 with the code gates backstopping; 3.5-flash is the
        // 10/10 pick available in Settings).
        .coachCardContent: LLMRoute(
            provider: .openAICompat,
            model: "google/gemini-3.1-flash-lite",
            baseURL: URL(string: "https://openrouter.ai/api/v1"),
            keychainAccount: "openrouter"
        ),
        .libraryQA: LLMRoute(
            provider: .openAICompat,
            model: "google/gemini-3.1-flash-lite",
            baseURL: URL(string: "https://openrouter.ai/api/v1"),
            keychainAccount: "openrouter"
        ),
        .conversationStateExtractor: LLMRoute(provider: .appleFM, model: "FoundationModels"),
    ]

    private static let defaultEmbeddingRoutes: [EmbeddingTaskClass: EmbeddingRoute] = [
        .embeddingsIndex: EmbeddingRoute(
            provider: .ollama,
            model: "nomic-embed-text",
            baseURL: URL(string: "http://127.0.0.1:11434")
        ),
        .embeddingsLive: EmbeddingRoute(
            provider: .ollama,
            model: "nomic-embed-text",
            baseURL: URL(string: "http://127.0.0.1:11434")
        ),
        .embeddingsRerank: EmbeddingRoute(
            provider: .openAICompat,
            model: "voyage-rerank-2.5",
            baseURL: URL(string: "https://api.voyageai.com/v1"),
            keychainAccount: "voyageai.api_key"
        ),
    ]

    private static let defaultHotkeys: HotkeyDefaults = .init(
        dictationPushToTalk: .init(key: "Space", modifiers: ["option"], tripleTap: false),
        manualCoachTrigger: .init(key: "Control", modifiers: [], tripleTap: true),
        openMainWindow: .init(key: "S", modifiers: ["command", "option"], tripleTap: false),
        globalSearchQA: .init(key: "K", modifiers: ["command"], tripleTap: false)
    )

    private static let defaultSparkle: SparkleDefaults = .init(
        feedURL: "https://github.com/bcssewl/trace/releases/latest/download/appcast.xml",
        publicEDKey: "bOFYSnRDpIR99coVgJeQSJB8u7ofVXQzBPCOitXiOXU=",
        enableAutomaticChecks: true,
        scheduledCheckIntervalSeconds: 86_400
    )

    private static let defaultStorage: StorageDefaults = .init(
        markdownRoot: "~/Documents/Trace",
        sqlitePath: "~/Library/Application Support/Trace/index.sqlite"
    )

    private static let defaultModelCaches: ModelCacheLocations = .init(
        fluidAudio: "~/Library/Application Support/Trace/FluidAudio",
        whisperKit: "~/Library/Application Support/Trace/WhisperKit",
        mlxModels: "~/Library/Application Support/Trace/MLX"
    )

    private static let defaultDiagnostics: DiagnosticsDefaults = .init(
        logRetentionDays: 14,
        exportAllowed: true
    )
}

extension BootstrapConfig {

    /// Loads the JSON variant of the config from a path.
    ///
    /// Returns `nil` if the
    /// file does not exist or fails to decode (caller falls back to `.bundled`).
    public static func load(from url: URL) -> BootstrapConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(BootstrapConfig.self, from: data)
        } catch {
            Loggers.storage.error(
                "BootstrapConfig.load failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Resolves the active configuration in this preference order.
    ///   1. Explicit `override` argument (test seam).
    ///   2. JSON file in `Bundle.main/Contents/Resources/BootstrapConfig.json`.
    ///   3. The compile-time `.bundled` default.
    public static func resolved(
        override: BootstrapConfig? = nil,
        bundle: Bundle = .main
    ) -> BootstrapConfig {
        if let override { return override }
        if let url = bundle.url(forResource: "BootstrapConfig", withExtension: "json"),
            let cfg = BootstrapConfig.load(from: url)
        {
            return cfg
        }
        return .bundled
    }
}
