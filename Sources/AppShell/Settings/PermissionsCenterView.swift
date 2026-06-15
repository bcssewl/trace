import SharedCore
import SwiftUI

/// Which feature group a permission belongs to (drives the section it appears
/// under in onboarding and the Permissions settings panel).
public enum PermissionGroup: Sendable, Hashable {
    case core
    case meetings
    case optional
}

/// One row in the canonical permission catalogue: the single source of truth for
/// what each macOS permission is, what it unlocks, and whether it's required —
/// shared by onboarding and the Permissions settings panel so the two never drift.
public struct PermissionCatalogEntry: Identifiable, Sendable, Hashable {
    public let kind: PermissionRequester.Kind
    public let icon: String
    public let name: String
    public let required: Bool
    public let group: PermissionGroup
    public let why: String
    public var id: PermissionRequester.Kind { kind }
}

public enum PermissionCatalog {
    public static let all: [PermissionCatalogEntry] = [
        PermissionCatalogEntry(
            kind: .microphone, icon: "mic.circle", name: "Microphone", required: true, group: .core,
            why:
                "Hears your voice for dictation, voice memos, and meetings. Without it Trace can't transcribe anything."
        ),
        PermissionCatalogEntry(
            kind: .accessibility, icon: "keyboard", name: "Accessibility", required: true, group: .core,
            why:
                "Types transcribed text straight into whatever app you're using, and powers the dictation hotkey. Without it text is copied for you to paste manually (⌘V)."
        ),
        PermissionCatalogEntry(
            kind: .systemAudio, icon: "speaker.wave.2", name: "System audio recording", required: true,
            group: .meetings,
            why:
                "Captures the other people on a call (Zoom, Meet, Teams, Discord) with no bot joining. macOS files this under \u{201C}Screen & System Audio Recording\u{201D}, but Trace records audio only, never video. Without it meetings record only your own mic."
        ),
        PermissionCatalogEntry(
            kind: .browserAwareness, icon: "globe", name: "Browser awareness", required: false, group: .meetings,
            why:
                "Reads your active browser tab (via macOS Apple Events) so Trace recognises which call you're in and can offer to start automatically. Without it you start meetings manually with ⌥M."
        ),
        PermissionCatalogEntry(
            kind: .speechRecognition, icon: "text.quote", name: "Speech recognition", required: false,
            group: .optional,
            why:
                "Powers Apple's built-in speech engine. Not needed with the on-device Parakeet model (the default) — only if you switch to Apple Speech."
        ),
        PermissionCatalogEntry(
            kind: .calendar, icon: "calendar", name: "Calendar", required: false, group: .optional,
            why:
                "Attaches transcripts to the matching event and uses its title and attendees as context. Read-only. Without it transcripts just aren't linked to events."
        ),
        PermissionCatalogEntry(
            kind: .notifications, icon: "bell", name: "Notifications", required: false, group: .optional,
            why:
                "Tells you when a transcription finishes or a paste fails. Without it you won't get those alerts."
        ),
    ]

    public static func group(_ g: PermissionGroup) -> [PermissionCatalogEntry] {
        all.filter { $0.group == g }
    }

    /// The permissions Trace actively verifies at launch and before a meeting —
    /// the ones whose absence silently breaks a core feature. (Browser awareness,
    /// speech, calendar and notifications are enhancers, surfaced but never
    /// blocking.)
    public static let launchCritical: [PermissionRequester.Kind] = [.microphone, .accessibility, .systemAudio]
}

/// Settings → Permissions: every macOS permission Trace can use, with its live
/// status and a one-tap grant — plus "Enable all" to run every prompt in one go.
/// This is the durable home the launch banner and the meeting-start notice both
/// deep-link to, so the user can review and fix permissions any time, not only
/// during onboarding.
@MainActor
public struct PermissionsCenterView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @State private var statuses: [PermissionRequester.Kind: PermissionStatus] = [:]
    @State private var busy = false
    private let requester = PermissionRequester()
    private let gate = PermissionGate()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Everything at once") {
                SettingsRow(
                    key: "Grant all the permissions Trace can use",
                    hint:
                        "Asks macOS for each permission in turn — one prompt at a time. You can still say no to any of them; nothing is forced on.",
                    showDivider: false
                ) {
                    BrutalistButton(busy ? "Asking…" : "Enable all", kind: .primary) {
                        Task { await enableAll() }
                    }
                    .disabled(busy)
                }
            }
            section("Core — needed to dictate", .core)
            section("For meetings", .meetings)
            section("Optional", .optional)
        }
        // Snapshot only — never auto-probe system audio here. A probe creates a
        // process tap, and doing that can leave a subsequent meeting's real tap
        // deaf; the explicit "Grant" button is the only place we create one.
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func section(_ title: String, _ group: PermissionGroup) -> some View {
        let rows = PermissionCatalog.group(group)
        return SettingsGroup(title) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, entry in
                SettingsRow(key: entry.name, hint: entry.why, showDivider: idx != rows.count - 1) {
                    statusControl(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func statusControl(_ entry: PermissionCatalogEntry) -> some View {
        let status = statuses[entry.kind] ?? .notDetermined
        HStack(spacing: 8) {
            switch status {
            case .granted:
                statusLabel("Granted", BrutalistPalette.semantic(scheme).success.color)
            case .denied, .restricted:
                statusLabel("Denied", palette.primary.color)
                BrutalistButton("Open Settings", kind: .ghost) {
                    requester.openSystemSettings(for: entry.kind)
                }
            case .notDetermined, .unknown:
                statusLabel("Not yet", palette.fgMuted.color)
                BrutalistButton("Grant", kind: entry.required ? .primary : .ghost) {
                    Task { statuses[entry.kind] = await requester.request(entry.kind) }
                }
            }
        }
    }

    private func statusLabel(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(BrutalistTypography.captionEmphasis)
                .foregroundStyle(color)
        }
    }

    private func enableAll() async {
        busy = true
        // Sequential so the macOS dialogs queue cleanly instead of racing.
        for entry in PermissionCatalog.all {
            statuses[entry.kind] = await requester.request(entry.kind)
        }
        busy = false
    }

    private func refresh() async {
        let snap = await gate.snapshot()
        statuses = [
            .microphone: snap.microphone,
            .accessibility: snap.accessibility,
            .systemAudio: snap.systemAudio,
            .browserAwareness: snap.browserAwareness,
            .speechRecognition: snap.speechRecognition,
            .calendar: snap.calendar,
            .notifications: snap.notifications,
        ]
    }
}
