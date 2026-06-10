import Foundation

/// The coach's behaviour config (persisted as JSON under
/// `app.trace.coach.config`, and per-project in `projects.coach_config`).
///
/// The listener redesign deliberately removed the old knobs — the five mode
/// toggles, the adaptive throttle, the anti-fabrication post-check, the
/// conversation-state ticker settings, and the concurrency cap. Old persisted
/// JSON still carrying those keys decodes cleanly (the tolerant decoder reads
/// only the keys below and `JSONDecoder` ignores strangers).
public struct CoachConfig: Sendable, Codable, Hashable {
    public var enabled: Bool
    /// Rolling card allowance: at most this many automatically surfaced cards
    /// within any trailing `surfaceWindowMinutes` window. The allowance refills
    /// as the window slides, so a long meeting keeps getting help instead of
    /// spending everything in the opening minutes (the old lifetime cap did
    /// exactly that on real meetings). Manual asks (triple-tap / the Ask chips)
    /// neither count against nor respect it.
    public var surfaceBudget: Int
    /// The trailing window (minutes) the `surfaceBudget` allowance applies to.
    /// Clamped to `minimumSurfaceWindowMinutes` at the point of use so a bad
    /// persisted value can never collapse the window into "no budget at all".
    public var surfaceWindowMinutes: Int
    /// How often (seconds) the listener may run a check when new conversation
    /// has arrived. Clamped to `minimumCheckCadenceSeconds` at the point of use
    /// so a bad persisted value can never produce a per-utterance call storm.
    public var checkCadenceSeconds: Int
    public var manualTrigger: ManualTriggerConfig

    /// Floor for `checkCadenceSeconds` — each check is a paid cloud call.
    public static let minimumCheckCadenceSeconds = 10

    /// Floor for `surfaceWindowMinutes` — a zero/negative window would mean no
    /// card ever counts against the budget.
    public static let minimumSurfaceWindowMinutes = 1

    /// `checkCadenceSeconds` with the safety floor applied.
    public var effectiveCheckCadenceSeconds: Int {
        max(Self.minimumCheckCadenceSeconds, checkCadenceSeconds)
    }

    /// `surfaceWindowMinutes` with the safety floor applied.
    public var effectiveSurfaceWindowMinutes: Int {
        max(Self.minimumSurfaceWindowMinutes, surfaceWindowMinutes)
    }

    public init(
        enabled: Bool = true,
        surfaceBudget: Int = 4,
        surfaceWindowMinutes: Int = 15,
        checkCadenceSeconds: Int = 20,
        manualTrigger: ManualTriggerConfig = .default
    ) {
        self.enabled = enabled
        self.surfaceBudget = surfaceBudget
        self.surfaceWindowMinutes = surfaceWindowMinutes
        self.checkCadenceSeconds = checkCadenceSeconds
        self.manualTrigger = manualTrigger
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, surfaceBudget, surfaceWindowMinutes, checkCadenceSeconds, manualTrigger
    }

    /// Tolerant decoder: each field falls back to its default when absent, so a
    /// config persisted by an older build (which had different fields — mode
    /// toggles, throttle settings, the conversation-state ticker) upgrades
    /// cleanly instead of failing to decode and silently resetting the user's
    /// entire Coach config to defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CoachConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.surfaceBudget = try c.decodeIfPresent(Int.self, forKey: .surfaceBudget) ?? d.surfaceBudget
        self.surfaceWindowMinutes =
            try c.decodeIfPresent(Int.self, forKey: .surfaceWindowMinutes) ?? d.surfaceWindowMinutes
        self.checkCadenceSeconds =
            try c.decodeIfPresent(Int.self, forKey: .checkCadenceSeconds) ?? d.checkCadenceSeconds
        self.manualTrigger = try c.decodeIfPresent(ManualTriggerConfig.self, forKey: .manualTrigger) ?? d.manualTrigger
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
