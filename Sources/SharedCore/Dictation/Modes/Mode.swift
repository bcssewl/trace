import Foundation

/// A per-application dictation mode.
///
/// Resolved from the frontmost application's bundle identifier by regex match;
/// the most-recently-edited candidate wins on ties.
///
/// Built-in modes (`isBuiltIn == true`) are immutable. Callers that need to
/// edit a built-in clone via `Mode.cloned(asCustomName:)` first.
///
/// `modelRouteOverride` is opt-in. When nil the controller uses the global
/// `LLMTaskClass.dictationCleanup` route from `ModelRouter`; when set, this
/// mode pins to a specific provider + model + endpoint.
///
/// `hotkeyOverride` is reserved for per-mode hotkey assignment. Most modes
/// inherit the global PTT binding configured in Settings.
public struct Mode: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var bundleIDRegex: String
    /// Optional website scope (BAS-5).
    ///
    /// When the frontmost app is a browser, the
    /// active tab URL is matched against this regex; a URL match outranks a
    /// bundle-ID match. `nil` means the mode is not website-scoped.
    public var urlRegex: String?
    public var hotkeyOverride: String?
    public var modelRouteOverride: LLMRoute?
    public var systemPrompt: String
    public var insertBehavior: InsertBehavior
    public var afterInsertBehavior: AfterInsertBehavior
    public var isBuiltIn: Bool
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval

    public init(
        id: UUID,
        name: String,
        bundleIDRegex: String,
        urlRegex: String? = nil,
        hotkeyOverride: String? = nil,
        modelRouteOverride: LLMRoute? = nil,
        systemPrompt: String,
        insertBehavior: InsertBehavior,
        afterInsertBehavior: AfterInsertBehavior,
        isBuiltIn: Bool,
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.bundleIDRegex = bundleIDRegex
        self.urlRegex = urlRegex
        self.hotkeyOverride = hotkeyOverride
        self.modelRouteOverride = modelRouteOverride
        self.systemPrompt = systemPrompt
        self.insertBehavior = insertBehavior
        self.afterInsertBehavior = afterInsertBehavior
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Builds a built-in mode.
    ///
    /// Built-ins refuse updates via `ModeRegistry.update(_:)`.
    public static func makeBuiltIn(
        id: UUID = UUID(),
        name: String,
        bundleIDRegex: String,
        systemPrompt: String,
        insertBehavior: InsertBehavior,
        afterInsertBehavior: AfterInsertBehavior,
        modelRouteOverride: LLMRoute? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Mode {
        Mode(
            id: id,
            name: name,
            bundleIDRegex: bundleIDRegex,
            hotkeyOverride: nil,
            modelRouteOverride: modelRouteOverride,
            systemPrompt: systemPrompt,
            insertBehavior: insertBehavior,
            afterInsertBehavior: afterInsertBehavior,
            isBuiltIn: true,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Builds a user-authored mode.
    ///
    /// New UUID each call.
    public static func makeCustom(
        name: String,
        bundleIDRegex: String,
        urlRegex: String? = nil,
        systemPrompt: String,
        insertBehavior: InsertBehavior,
        afterInsertBehavior: AfterInsertBehavior,
        modelRouteOverride: LLMRoute? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Mode {
        Mode(
            id: UUID(),
            name: name,
            bundleIDRegex: bundleIDRegex,
            urlRegex: urlRegex,
            hotkeyOverride: nil,
            modelRouteOverride: modelRouteOverride,
            systemPrompt: systemPrompt,
            insertBehavior: insertBehavior,
            afterInsertBehavior: afterInsertBehavior,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Compiles `bundleIDRegex` lazily.
    ///
    /// Throws `TraceError.configInvalid` if the pattern fails to compile.
    public func compiledBundleIDRegex() throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: bundleIDRegex, options: [])
        } catch {
            throw TraceError.configInvalid(
                field: "Mode.bundleIDRegex",
                reason: "Pattern \(bundleIDRegex) failed to compile: \(error.localizedDescription)"
            )
        }
    }

    /// Compiles `urlRegex` (case-insensitive), or returns `nil` when the mode is
    /// not website-scoped.
    ///
    /// Throws `TraceError.configInvalid` on a bad pattern.
    public func compiledURLRegex() throws -> NSRegularExpression? {
        guard let urlRegex, !urlRegex.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: urlRegex, options: [.caseInsensitive])
        } catch {
            throw TraceError.configInvalid(
                field: "Mode.urlRegex",
                reason: "Pattern \(urlRegex) failed to compile: \(error.localizedDescription)"
            )
        }
    }

    /// Produces an editable custom copy of this mode under the supplied name.
    public func cloned(asCustomName name: String, now: TimeInterval = Date().timeIntervalSince1970) -> Mode {
        Mode(
            id: UUID(),
            name: name,
            bundleIDRegex: bundleIDRegex,
            urlRegex: urlRegex,
            hotkeyOverride: hotkeyOverride,
            modelRouteOverride: modelRouteOverride,
            systemPrompt: systemPrompt,
            insertBehavior: insertBehavior,
            afterInsertBehavior: afterInsertBehavior,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Refreshes the `updatedAt` timestamp.
    ///
    /// Used by the registry's update flow to keep most-recently-edited
    /// tie-breaks correct.
    public mutating func touch(at timestamp: TimeInterval = Date().timeIntervalSince1970) {
        updatedAt = timestamp
    }
}
