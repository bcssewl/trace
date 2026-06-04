import Foundation

public actor BurstDecayThrottle {
    public enum Tier: Sendable, Hashable {
        case hot
        case medium
        case cold

        public var minSpacingSeconds: TimeInterval {
            switch self {
            case .hot: return 0
            case .medium: return 4
            case .cold: return 12
            }
        }

        public var replacementDelta: Double {
            switch self {
            case .hot: return 0.05
            case .medium: return 0.10
            case .cold: return 0.20
            }
        }
    }

    public struct Decision: Sendable, Hashable {
        public let allow: Bool
        public let tier: Tier
        public let reason: String

        public init(allow: Bool, tier: Tier, reason: String) {
            self.allow = allow
            self.tier = tier
            self.reason = reason
        }
    }

    private var lastSurfacedAt: Date?
    private var lastSurfacedScore: Double?
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public static func tier(forBurstScore score: Double) -> Tier {
        switch score {
        case let s where s > 0.7: return .hot
        case let s where s >= 0.5: return .medium
        default: return .cold
        }
    }

    public static func burstScore(questionDensity: Double, kbRelevance: Double) -> Double {
        (questionDensity * 0.4) + (kbRelevance * 0.6)
    }

    public func evaluate(candidateScore: Double, userRequested: Bool = false) -> Decision {
        let tier = Self.tier(forBurstScore: candidateScore)
        if userRequested {
            recordSurface(score: candidateScore)
            return Decision(allow: true, tier: tier, reason: "user-requested override")
        }
        let now = clock()
        if let lastAt = lastSurfacedAt {
            let elapsed = now.timeIntervalSince(lastAt)
            if elapsed < tier.minSpacingSeconds,
                let lastScore = lastSurfacedScore,
                candidateScore < lastScore + tier.replacementDelta
            {
                return Decision(
                    allow: false, tier: tier,
                    reason:
                        "spacing \(Int(elapsed))s < \(Int(tier.minSpacingSeconds))s AND not strong enough to preempt"
                )
            }
        }
        recordSurface(score: candidateScore)
        return Decision(allow: true, tier: tier, reason: "preempt or fresh slot")
    }

    public func reset() {
        lastSurfacedAt = nil
        lastSurfacedScore = nil
    }

    private func recordSurface(score: Double) {
        lastSurfacedAt = clock()
        lastSurfacedScore = score
    }
}
