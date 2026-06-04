import AppKit
import SharedCore
import SwiftUI

@MainActor
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    public let state: AppStateModel
    public let palette: BrutalistPalette.Pair
    public let commands: AppCommands
    /// Recent meetings shown in the idle dropdown — refreshed each time the popover
    /// opens, without disturbing the main window's library scope.
    let recents = MenuBarRecentsModel()

    public init(state: AppStateModel, palette: BrutalistPalette.Pair, commands: AppCommands) {
        self.state = state
        self.palette = palette
        self.commands = commands
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        configure()
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.action = #selector(toggle)
            button.target = self
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverHostView(
                state: state, palette: palette, commands: commands, recents: recents)
        )
        // Best-effort warm load so the first open already shows recent meetings
        // (a no-op until the coordinator has wired the library loader).
        Task { await refreshRecents() }
    }

    /// The custom Trace mark as a monochrome menu-bar template (auto-tinted by
    /// macOS for light/dark).
    ///
    /// Falls back to the system waveform symbol if the
    /// bundled asset can't be loaded.
    private static func menuBarImage() -> NSImage? {
        let url =
            Bundle.module.url(forResource: "TraceMenuBar", withExtension: "png", subdirectory: "Resources/Logos")
            ?? Bundle.module.url(forResource: "TraceMenuBar", withExtension: "png", subdirectory: "Logos")
        if let url, let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 20, height: 20)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Trace")
        fallback?.isTemplate = true
        return fallback
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Match the app's Light/Dark choice the same way the coach panel does,
            // and refresh the recent-meetings list, before showing.
            applyAppearance()
            Task { await refreshRecents() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Force the popover to the app's Appearance setting (System / Light / Dark),
    /// mirroring `CoachOverlayController.applyAppearance`.
    ///
    /// A menu-bar popover otherwise follows the *system* appearance and silently
    /// ignores the in-app choice, so it diverges from the coach whenever the user
    /// locks Trace to Light or Dark.
    private func applyAppearance() {
        switch state.appearancePreference.preferredScheme {
        case .some(.light): popover.appearance = NSAppearance(named: .aqua)
        case .some(.dark): popover.appearance = NSAppearance(named: .darkAqua)
        default: popover.appearance = nil
        }
    }

    /// Load the most-recent meetings for the idle dropdown via the library's own
    /// loader, WITHOUT mutating `meetingLibrary.meetings`/scope (the main window
    /// owns that). A no-op until the coordinator has wired `loadList`.
    ///
    /// Capped at four: the idle dropdown is a fixed-height (460pt) popover with no
    /// scroll view, and four recent rows is the most that fits below the
    /// quick-capture actions without clipping the pinned library/settings/quit rows.
    private func refreshRecents() async {
        guard let load = state.meetingLibrary.loadList else { return }
        recents.items = Array(await load(nil).prefix(4))
    }
}

/// Backing store for the menu-bar dropdown's "Recent meetings" list.
///
/// Owned by `MenuBarController` and refreshed on each popover open; kept separate
/// from `MeetingLibraryModel` so listing here never changes what the main library
/// window is currently showing.
@MainActor
@Observable
final class MenuBarRecentsModel {
    var items: [SessionMetadata] = []
}

@MainActor
struct MenuBarPopoverHostView: View {
    @Bindable var state: AppStateModel
    let palette: BrutalistPalette.Pair
    let commands: AppCommands
    let recents: MenuBarRecentsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Resolve the palette from the explicit Light/Dark choice when the user has
        // locked one (only falling back to the ambient scheme for "System"), so the
        // dropdown honours the setting directly rather than depending on the
        // popover's NSAppearance round-trip reaching `@Environment(\.colorScheme)`.
        let resolvedScheme = state.appearancePreference.preferredScheme ?? scheme
        MenuBarPopoverContentView(state: state, commands: commands, recents: recents)
            .environment(\.brutalistPalette, palette.resolve(resolvedScheme))
    }
}

struct MenuBarPopoverContentView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var state: AppStateModel
    let commands: AppCommands
    let recents: MenuBarRecentsModel

    private var captureMode: ActiveCaptureModel.CaptureMode { state.activeCapture.mode }

    /// The custom Trace mark as a tintable template image, for the popover header.
    static let traceGlyph: Image = {
        let url =
            Bundle.module.url(forResource: "TraceMenuBar", withExtension: "png", subdirectory: "Resources/Logos")
            ?? Bundle.module.url(forResource: "TraceMenuBar", withExtension: "png", subdirectory: "Logos")
        if let url, let ns = NSImage(contentsOf: url) {
            ns.isTemplate = true
            return Image(nsImage: ns).renderingMode(.template)
        }
        return Image(systemName: "waveform")
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            content
        }
        .frame(width: 360, height: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: BrutalistMetrics.popoverCornerRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if captureMode == .idle {
                    Self.traceGlyph
                        .resizable().scaledToFit().frame(width: 14, height: 14)
                        .foregroundStyle(palette.fg.color)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.primary.color)
                }
            }
            Text(headerTitle)
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            Spacer()
            // Live timer driven by ActiveCaptureModel.startedAt, ticking 1Hz via
            // TimelineView while a session is active. Static "v0.1.0" when idle.
            if let startedAt = state.activeCapture.startedAt {
                TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                    Text(elapsedString(since: startedAt, now: ctx.date))
                        .font(BrutalistTypography.mono11)
                        .foregroundStyle(palette.primary.color)
                }
            } else if let version = AppVersion.label {
                Text(version)
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func elapsedString(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var headerTitle: String {
        switch captureMode {
        case .idle: return "Trace"
        case .dictation: return "Dictating"
        case .voiceMemo: return "Voice memo"
        case .meeting: return "Meeting"
        }
    }

    /// Open a past meeting in the main window from the dropdown.
    ///
    /// Activates the window and posts the same deep-link the Library uses; the
    /// transient popover closes on its own as focus moves to the window.
    private func openMeeting(_ meta: SessionMetadata) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
        NotificationCenter.default.post(
            name: .traceOpenMeeting,
            object: OpenMeetingRequest(meetingId: meta.sessionId)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch captureMode {
        case .idle: idleContent
        case .dictation, .voiceMemo: dictationContent
        case .meeting: meetingContent
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Quick capture")
            popRow(symbol: "mic.circle", text: "Start dictation", kbd: "⌥ Space", action: commands.startDictation)
            popRow(symbol: "waveform", text: "Voice memo", kbd: "⌥ V", action: commands.startVoiceMemo)
            popRow(symbol: "person.2.wave.2", text: "Start meeting", kbd: "⌥ M", action: commands.startMeeting)
            popRow(symbol: "doc.badge.arrow.up", text: "Transcribe file…", kbd: "⌥ F", action: commands.transcribeFile)
            sectionLabel("Recent meetings")
            if recents.items.isEmpty {
                HStack {
                    Text("Nothing here yet")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            } else {
                ForEach(recents.items, id: \.sessionId) { meta in
                    popRow(
                        symbol: "person.2.wave.2",
                        text: meta.title?.isEmpty == false ? meta.title! : "Untitled meeting",
                        kbd: RelativeFormat.relativeTime(meta.startedAt),
                        action: { openMeeting(meta) }
                    )
                }
            }
            Spacer()
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            popRow(symbol: "books.vertical", text: "Open library", kbd: "⌘ O", action: commands.openLibrary)
            popRow(symbol: "gearshape", text: "Settings…", kbd: "⌘ ,", action: commands.openSettings)
            popRow(symbol: "power", text: "Quit", kbd: "⌘ Q", action: commands.quit)
        }
    }

    private var dictationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Status")
            popRow(
                symbol: "circle.fill",
                text: captureMode == .voiceMemo ? "Recording a voice memo" : "Recording dictation",
                kbd: state.activeCapture.sessionId.map { String($0.suffix(8)) } ?? "—",
                active: true
            )
            sectionLabel("Controls")
            popRow(symbol: "stop.circle", text: "Stop", kbd: "⌘ ⇧ .", action: stopCaptureAction)
            Spacer()
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            popRow(symbol: "books.vertical", text: "Open library", kbd: "⌘ O", action: commands.openLibrary)
            popRow(symbol: "gearshape", text: "Settings…", kbd: "⌘ ,", action: commands.openSettings)
        }
    }

    private var stopCaptureAction: () -> Void {
        captureMode == .voiceMemo ? commands.stopVoiceMemo : commands.stopDictation
    }

    private var meetingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Status")
            popRow(
                symbol: "circle.fill",
                text: "Recording a meeting",
                kbd: state.activeCapture.sessionId.map { String($0.suffix(8)) } ?? "—",
                active: true
            )
            sectionLabel("Controls")
            popRow(symbol: "stop.circle", text: "Stop & finalize", kbd: "⌘ ⇧ .", action: commands.stopMeeting)
            Spacer()
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            popRow(symbol: "books.vertical", text: "Open library", kbd: "⌘ O", action: commands.openLibrary)
            popRow(symbol: "gearshape", text: "Settings…", kbd: "⌘ ,", action: commands.openSettings)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(BrutalistTypography.groupTitle)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func popRow(
        symbol: String, text: String, kbd: String, active: Bool = false, action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: active ? 9 : 13))
                    .foregroundStyle(active ? palette.primary.color : palette.fgMuted.color)
                    .frame(width: 16, alignment: .center)
                Text(text)
                    .font(BrutalistTypography.label)
                    .foregroundStyle(palette.fg.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(kbd)
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(active ? palette.primary.color : palette.fgMuted.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(active ? palette.primary.color.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
