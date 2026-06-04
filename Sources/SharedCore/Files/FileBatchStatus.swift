import Foundation

/// Lifecycle stages for a `FileBatchJob`.
///
/// Mirrors the `status` column of the
/// `files` table in schema v6. The values are persisted as text so the set
/// must stay stable; add new states only after a migration plan.
public enum FileBatchStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case queued
    case extracting
    case transcribing
    case summarizing
    case writing
    case completed
    case failed
    case cancelled

    /// Stages still owning the job within the controller pipeline.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .extracting, .transcribing, .summarizing, .writing:
            return false
        }
    }

    /// Ordered progress weight for UI affordances.
    ///
    /// Sums to one across the live
    /// pipeline stages. Terminal states pin to one.
    public var progressFraction: Double {
        switch self {
        case .queued: return 0
        case .extracting: return 0.10
        case .transcribing: return 0.55
        case .summarizing: return 0.85
        case .writing: return 0.95
        case .completed, .failed, .cancelled: return 1.0
        }
    }
}

/// A reason captured alongside a `failed` or `cancelled` status.
///
/// Carried in the
/// `error_reason` column and surfaced unchanged to the UI.
public struct FileBatchFailure: Sendable, Codable, Hashable {
    public let stage: FileBatchStatus
    public let reason: String

    public init(stage: FileBatchStatus, reason: String) {
        self.stage = stage
        self.reason = reason
    }
}
