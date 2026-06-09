import Foundation
import Observation
import SharedCore

/// Central, user-visible surface for failures and notable events.
///
/// The error taxonomy (`TraceError`) has always known *how* to recover —
/// `recoveryAction` names the exact System Settings pane to open — but until
/// this type existed nothing consumed it: coordinator-level catches logged and
/// moved on, leaving the user with a silent no-op. Every "this failed but the
/// app kept going" path now posts here, and the main window renders the queue
/// as dismissible banners with working recovery buttons.
///
/// Posting rules:
/// * Failures the user must act on (permission denied, model missing, key
///   invalid) are `.error` — they stay until dismissed.
/// * Degradations the app survives but the user should know about (search
///   index stale, a meeting filed in memory only) are `.warning` — they stay
///   until dismissed.
/// * Confirmations of self-healing (capture recovered, recovered dictation
///   found) are `.info` — they dismiss themselves.
/// * A `coalescingKey` collapses repeats: a dead Ollama posts ONE banner no
///   matter how many refreshes fail while it's down.
@MainActor
@Observable
public final class AppNoticeCenter {

    /// What a banner's button does. Executed by the banner view, which owns
    /// the navigation context (app state for the in-app Settings takeover).
    public enum NoticeAction: Identifiable, Sendable {
        /// Open Trace's own Settings at a specific tab (in-window takeover).
        case openSettingsTab(SettingsTab, label: String)
        /// Open a macOS System Settings pane (TCC privacy panes etc.).
        /// `pane` uses `TraceError.RecoveryAction` conventions: either a
        /// `Privacy_*` anchor on the security pane or a full
        /// `com.apple.preference.*` pane identifier.
        case openSystemSettings(pane: String, label: String)
        /// Caller-supplied recovery (e.g. retry a refresh).
        case custom(label: String, handler: @MainActor @Sendable () -> Void)

        public var label: String {
            switch self {
            case .openSettingsTab(_, let label): return label
            case .openSystemSettings(_, let label): return label
            case .custom(let label, _): return label
            }
        }

        public var id: String { label }

        /// The `x-apple.systempreferences` URL for a `openSystemSettings` pane
        /// string, mirroring `PermissionRequester.Kind.settingsPaneURL`.
        public static func systemSettingsURL(pane: String) -> URL? {
            let raw =
                pane.hasPrefix("com.apple.")
                ? "x-apple.systempreferences:\(pane)"
                : "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            return URL(string: raw)
        }
    }

    public struct Notice: Identifiable, Sendable {
        public enum Severity: Sendable {
            case info
            case warning
            case error
        }

        public let id: UUID
        public let severity: Severity
        public let title: String
        public let message: String
        public let actions: [NoticeAction]
        public let date: Date
        /// Repeats with the same key replace the older banner instead of
        /// stacking.
        public let coalescingKey: String?
    }

    public private(set) var notices: [Notice] = []

    /// How long `.info` notices linger before dismissing themselves.
    private let infoLifetime: Duration = .seconds(6)

    public init() {}

    /// Post a notice. Returns its id (useful for later programmatic dismissal,
    /// e.g. clearing a "model unavailable" banner when the model recovers).
    @discardableResult
    public func post(
        severity: Notice.Severity,
        title: String,
        message: String,
        actions: [NoticeAction] = [],
        coalescingKey: String? = nil
    ) -> UUID {
        if let coalescingKey {
            notices.removeAll { $0.coalescingKey == coalescingKey }
        }
        let notice = Notice(
            id: UUID(),
            severity: severity,
            title: title,
            message: message,
            actions: actions,
            date: Date(),
            coalescingKey: coalescingKey
        )
        notices.append(notice)
        if severity == .info {
            let id = notice.id
            let lifetime = infoLifetime
            Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                self?.dismiss(id)
            }
        }
        return notice.id
    }

    /// Post a `TraceError`, deriving the recovery button from the error's own
    /// `recoveryAction` so the taxonomy's knowledge finally reaches the user.
    @discardableResult
    public func post(
        _ error: TraceError,
        title: String,
        severity: Notice.Severity = .error,
        extraActions: [NoticeAction] = [],
        coalescingKey: String? = nil
    ) -> UUID {
        var actions = extraActions
        switch error.recoveryAction {
        case .openSystemSettings(let pane):
            actions.append(.openSystemSettings(pane: pane, label: "Open System Settings"))
        case .promptUserToReconnect, .retryWithBackoff, .none:
            break
        }
        return post(
            severity: severity,
            title: title,
            message: error.localizedDescription,
            actions: actions,
            coalescingKey: coalescingKey
        )
    }

    public func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    /// Clear a coalesced banner (e.g. when the failing dependency recovers).
    public func clear(coalescingKey: String) {
        notices.removeAll { $0.coalescingKey == coalescingKey }
    }

    public func dismissAll() {
        notices.removeAll()
    }
}
