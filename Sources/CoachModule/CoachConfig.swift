import Foundation

public struct CoachConfig: Sendable, Codable, Hashable {
    public var enabled: Bool
    public var modes: ModeToggles
    public var surfaceBudget: Int
    public var adaptiveThrottle: Bool
    public var antiFabricationPostCheck: Bool
    /// Whether the conversation-state extractor runs during a meeting to feed the
    /// coach smart-router live context (spec §5 stage; default on).
    ///
    /// Local/cloud
    /// routing is governed separately by the `.conversationStateExtractor` model route.
    public var conversationStateEnabled: Bool
    /// How often (seconds) the conversation-state running summary refreshes.
    ///
    /// Default
    /// 30 (spec §5/§407 "~30s"). A longer interval means fewer model calls — which
    /// matters when the stage is routed to a paid cloud model.
    public var conversationStateIntervalSeconds: Int
    public var manualTrigger: ManualTriggerConfig

    public init(
        enabled: Bool = true,
        modes: ModeToggles = .default,
        surfaceBudget: Int = 8,
        adaptiveThrottle: Bool = true,
        antiFabricationPostCheck: Bool = false,
        conversationStateEnabled: Bool = true,
        conversationStateIntervalSeconds: Int = 30,
        manualTrigger: ManualTriggerConfig = .default
    ) {
        self.enabled = enabled
        self.modes = modes
        self.surfaceBudget = surfaceBudget
        self.adaptiveThrottle = adaptiveThrottle
        self.antiFabricationPostCheck = antiFabricationPostCheck
        self.conversationStateEnabled = conversationStateEnabled
        self.conversationStateIntervalSeconds = conversationStateIntervalSeconds
        self.manualTrigger = manualTrigger
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, modes, surfaceBudget, adaptiveThrottle
        case antiFabricationPostCheck, conversationStateEnabled
        case conversationStateIntervalSeconds, manualTrigger
    }

    /// Tolerant decoder: each field falls back to its default when absent, so a
    /// config persisted by an older build (which predates a newer field like
    /// `conversationStateEnabled`) upgrades cleanly instead of failing to decode
    /// and silently resetting the user's entire Coach config to defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CoachConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.modes = try c.decodeIfPresent(ModeToggles.self, forKey: .modes) ?? d.modes
        self.surfaceBudget = try c.decodeIfPresent(Int.self, forKey: .surfaceBudget) ?? d.surfaceBudget
        self.adaptiveThrottle = try c.decodeIfPresent(Bool.self, forKey: .adaptiveThrottle) ?? d.adaptiveThrottle
        self.antiFabricationPostCheck =
            try c.decodeIfPresent(Bool.self, forKey: .antiFabricationPostCheck) ?? d.antiFabricationPostCheck
        self.conversationStateEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .conversationStateEnabled) ?? d.conversationStateEnabled
        self.conversationStateIntervalSeconds =
            try c.decodeIfPresent(Int.self, forKey: .conversationStateIntervalSeconds)
            ?? d.conversationStateIntervalSeconds
        self.manualTrigger = try c.decodeIfPresent(ManualTriggerConfig.self, forKey: .manualTrigger) ?? d.manualTrigger
    }

    public struct ModeToggles: Sendable, Codable, Hashable {
        public var grounded: Bool
        public var synthesized: Bool
        public var general: Bool
        public var reframe: Bool
        public var agenda: Bool

        public init(
            grounded: Bool = true, synthesized: Bool = true, general: Bool = true,
            reframe: Bool = true, agenda: Bool = true
        ) {
            self.grounded = grounded
            self.synthesized = synthesized
            self.general = general
            self.reframe = reframe
            self.agenda = agenda
        }

        public static let `default` = ModeToggles()
    }

    public struct ManualTriggerConfig: Sendable, Codable, Hashable {
        public var enabled: Bool
        public var modifierKeyCode: Int
        public var tapCount: Int
        public var windowMilliseconds: Int

        public init(
            enabled: Bool = true,
            modifierKeyCode: Int = 0x3D,
            tapCount: Int = 3,
            windowMilliseconds: Int = 500
        ) {
            self.enabled = enabled
            self.modifierKeyCode = modifierKeyCode
            self.tapCount = tapCount
            self.windowMilliseconds = windowMilliseconds
        }

        public static let `default` = ManualTriggerConfig()
    }
}
