import Foundation

/// Module marker. `SharedCore` is the foundation layer that every higher-level
/// module imports.
///
/// The bootstrap-related types in this folder install the
/// default LLM / embedding / Sparkle configuration on first run.
public enum SharedCore {
    public static let moduleName = "SharedCore"
}
