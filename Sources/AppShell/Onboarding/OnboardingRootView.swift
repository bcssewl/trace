import AppKit
import SharedCore
import SwiftUI

@MainActor
public struct OnboardingRootView: View {
    @Environment(\.brutalistPalette) private var palette
    @State private var state: OnboardingStateModel
    /// The real, persisted app settings.
    ///
    /// The speech, AI, and shortcut steps bind
    /// straight to this so a choice made here is the same preference Settings
    /// shows later — no separate onboarding copy to sync.
    private let appState: AppStateModel
    public var onComplete: () -> Void
    public var onOpenLibrary: () -> Void
    public var onStartDictation: () -> Void

    public init(
        projectStore: ProjectStore? = nil,
        appState: AppStateModel,
        asrInstall: AsrModelInstallCoordinator,
        onComplete: @escaping () -> Void,
        onOpenLibrary: (() -> Void)? = nil,
        onStartDictation: (() -> Void)? = nil
    ) {
        _state = State(initialValue: OnboardingStateModel(projectStore: projectStore, asrInstall: asrInstall))
        self.appState = appState
        self.onComplete = onComplete
        self.onOpenLibrary = onOpenLibrary ?? onComplete
        self.onStartDictation = onStartDictation ?? onComplete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressRow
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline)
            ScrollView {
                stepBody
                    .padding(.horizontal, 56)
                    .padding(.vertical, 48)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline)
            footer
        }
        .background(palette.background.color)
        .frame(minWidth: 920, minHeight: 600)
        .task {
            await state.refreshPermissions()
            await state.probeModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-probe permissions whenever the user returns from System Settings.
            Task { await state.refreshPermissions() }
        }
    }

    private var progressRow: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("Step \(state.currentStep.rawValue) of \(state.totalSteps)")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                Text("·")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                Text(state.currentStep.label)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fg.color)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(palette.accentBg.color).frame(height: 3)
                GeometryReader { proxy in
                    Capsule()
                        .fill(palette.primary.color)
                        .frame(width: proxy.size.width * state.progressFraction, height: 3)
                }
                .frame(height: 3)
            }
            Text(state.currentStep.estimate)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch state.currentStep {
        case .welcome: OnboardingWelcomeView()
        case .permissions: OnboardingPermissionsView(state: state)
        case .speech: OnboardingSpeechView(state: state, appState: appState)
        case .ai: OnboardingAIView(state: state, appState: appState)
        case .shortcuts: OnboardingShortcutsView(appState: appState)
        case .tryIt: OnboardingTryView(state: state, appState: appState)
        case .done: OnboardingDoneView(state: state, appState: appState)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if state.currentStep != .welcome {
                BrutalistButton("Back", kind: .ghost) { state.goPrevious() }
            } else {
                BrutalistButton("Quit", kind: .ghost) { NSApplication.shared.terminate(nil) }
            }
            Spacer()
            switch state.currentStep {
            case .done:
                BrutalistButton("Open Library", kind: .ghost) { onOpenLibrary() }
                BrutalistButton("Start using Trace", kind: .primary) { onStartDictation() }
            case .speech:
                // The download is owned by the long-lived install coordinator, so
                // Continue never cancels it. While downloading, offer Pause + a
                // "continue while it downloads" path (matches the prototype).
                if state.speechEngine == .parakeet && state.asrInstall.isDownloading {
                    BrutalistButton("Pause", kind: .ghost) { state.asrInstall.pause() }
                    BrutalistButton("Continue while it downloads", kind: .primary) { state.goNext() }
                } else {
                    BrutalistButton("Continue", kind: .primary) { state.goNext() }
                }
            default:
                BrutalistButton("Continue", kind: .primary) { state.goNext() }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(palette.bgTertiary.color)
    }
}

// MARK: - Shared bits

/// A muted footnote stating exactly what skipping leaves you with.
@MainActor
struct OnboardingSkipNote: View {
    @Environment(\.brutalistPalette) private var palette
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.fgMuted.color)
            Text(text)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.horizontal, 4)
        .frame(maxWidth: 680, alignment: .leading)
    }
}

/// Card container matching the prototype `.card` (bgCard + soft border).
@MainActor
struct OnboardingCard<Content: View>: View {
    @Environment(\.brutalistPalette) private var palette
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.bgCard.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
            )
    }
}

@MainActor
func onboardingDivider(_ palette: BrutalistPalette, leading: CGFloat = 16) -> some View {
    Rectangle()
        .fill(palette.borderSoft.color)
        .frame(height: BrutalistMetrics.hairline)
        .padding(.leading, leading)
}

// MARK: - 1. Welcome

@MainActor
struct OnboardingWelcomeView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Trace")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
                .padding(.bottom, 12)
            HStack(spacing: 7) {
                Circle().fill(BrutalistPalette.semantic(scheme).success.color).frame(width: 6, height: 6)
                Text("Runs on your Mac · no bot ever joins your calls")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgSidebar.color)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(palette.secondary.color)
            )
            .overlay(Capsule().stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline))
            .padding(.bottom, 22)

            Text(
                "Trace turns your voice into text anywhere, captures your meetings, transcribes your files, and coaches you live. It all runs on on-device models by default, with your own data staying on your machine. Setup takes about two minutes, and you can skip any step and change it later."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.bottom, 26)
            .frame(maxWidth: 640, alignment: .leading)

            OnboardingCard {
                wedge(
                    icon: "mic.circle", name: "Dictation",
                    desc:
                        "Hold a hotkey, talk, and your words land at the cursor in any app, cleaned up automatically.",
                    divider: false)
                onboardingDivider(palette)
                wedge(
                    icon: "person.2.wave.2", name: "Meetings",
                    desc:
                        "Captures your mic and the call audio locally. No bot, and it works on any platform (Zoom, Meet, Teams).",
                    divider: false)
                onboardingDivider(palette)
                wedge(
                    icon: "doc.badge.arrow.up", name: "Files & memos",
                    desc: "Drop in audio or lectures; iPhone voice memos sync over. Same AI notes as meetings.",
                    divider: false)
                onboardingDivider(palette)
                wedge(
                    icon: "sparkles", name: "Coach",
                    desc: "Live cue cards during calls, grounded in your playbooks. Invisible to screen share.",
                    divider: false)
            }
        }
    }

    private func wedge(icon: String, name: String, desc: String, divider: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(palette.primary.color)
                .frame(width: 26, alignment: .center)
                .padding(.top, 1)
            Text(name)
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
                .frame(width: 120, alignment: .leading)
            Text(desc)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

// MARK: - 2. Permissions

@MainActor
struct OnboardingPermissionsView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Bindable var state: OnboardingStateModel

    private struct Row: Identifiable {
        let kind: PermissionRequester.Kind
        let icon: String
        let name: String
        let required: Bool
        let why: String
        var id: PermissionRequester.Kind { kind }
    }

    private let core: [Row] = [
        Row(
            kind: .microphone, icon: "mic.circle", name: "Microphone", required: true,
            why: "Hears your voice for dictation, voice memos, and meetings. Skip and Trace can't transcribe anything."),
        Row(
            kind: .accessibility, icon: "keyboard", name: "Accessibility", required: true,
            why:
                "Types the transcribed text into whatever app you're using. Skip and text is copied to the clipboard for you to paste manually (⌘V)."
        ),
    ]
    private let meetings: [Row] = [
        Row(
            kind: .systemAudio, icon: "speaker.wave.2", name: "System audio recording", required: false,
            why:
                "Captures the other people on a call (Zoom, Meet, Teams, Discord) with no bot joining. macOS files this under \u{201C}Screen & System Audio Recording,\u{201D} but Trace records audio only, never video. Skip and meetings record only your own mic."
        ),
        Row(
            kind: .browserAwareness, icon: "globe", name: "Browser awareness", required: false,
            why:
                "Reads your active browser tab (via macOS Apple Events) so Trace can recognize which call you're in and start capturing automatically. Skip and you start meetings manually with ⌥M."
        ),
    ]
    private let optional: [Row] = [
        Row(
            kind: .speechRecognition, icon: "text.quote", name: "Speech recognition", required: false,
            why:
                "Powers Apple's built-in speech engine, used as a fallback. Not needed if you use the on-device Parakeet model (the default). Skip it unless you switch to Apple Speech."
        ),
        Row(
            kind: .calendar, icon: "calendar", name: "Calendar", required: false,
            why:
                "Auto-attaches transcripts to the matching event and uses its title and attendees as context. Read-only. Skip and transcripts just aren't linked to events."
        ),
        Row(
            kind: .notifications, icon: "bell", name: "Notifications", required: false,
            why: "Tells you when a transcription finishes or a paste fails. Skip and you won't get those alerts."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permissions")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text(
                "Trace can use the macOS permissions below, grouped by what they unlock. Here's exactly what each one does and what you give up by skipping it. Turn on the ones you want; you're always in control and can change any of them later in System Settings or from the menu bar."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.vertical, 16)
            .frame(maxWidth: 640, alignment: .leading)

            group("Core — needed to dictate", core)
            group("For meetings", meetings)
            group("Optional", optional)

            OnboardingSkipNote(
                "Skipping is safe. Leave any row off and macOS simply asks the first time you use that feature. Nothing breaks silently. The only sticky case is actively denying one: then the row links straight to the exact System Settings toggle and Trace re-checks the moment you switch back. Only Microphone + Accessibility are needed for core dictation."
            )
        }
        .task { await state.refreshPermissions() }
    }

    private func group(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(BrutalistTypography.groupTitle)
                .foregroundStyle(palette.fgMuted.color)
                .padding(.horizontal, 4)
            OnboardingCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    permRow(row)
                    if idx < rows.count - 1 { onboardingDivider(palette) }
                }
            }
        }
        .padding(.top, 22)
    }

    private func permRow(_ row: Row) -> some View {
        let status = state.permissionState[row.kind] ?? .notDetermined
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: row.icon)
                .font(.system(size: 13))
                .foregroundStyle(palette.fgSidebar.color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(palette.secondary.color))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(BrutalistTypography.labelEmphasis)
                        .foregroundStyle(palette.fg.color)
                    pill(required: row.required)
                }
                Text(row.why)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
            }
            Spacer(minLength: 0)
            statusControl(row: row, status: status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private func pill(required: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(required ? palette.primary.color : palette.fgMuted.color)
                .frame(width: 5, height: 5)
            Text(required ? "Required" : "Optional")
                .font(BrutalistTypography.captionEmphasis)
                .foregroundStyle(required ? palette.primary.color : palette.fgMuted.color)
        }
    }

    @ViewBuilder
    private func statusControl(row: Row, status: PermissionStatus) -> some View {
        HStack(spacing: 8) {
            if status == .granted {
                statusLabel("Granted", color: BrutalistPalette.semantic(scheme).success.color)
            } else if status == .denied || status == .restricted {
                statusLabel("Denied", color: palette.primary.color)
                BrutalistButton("Open Settings", kind: .ghost) {
                    state.openPermissionSettings(row.kind)
                }
            } else {
                statusLabel("Pending", color: palette.fgMuted.color)
                BrutalistButton("Grant", kind: row.required ? .primary : .ghost) {
                    Task { await state.requestPermission(row.kind) }
                }
            }
        }
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(BrutalistTypography.captionEmphasis)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Pipeline strip (speech + AI steps)

@MainActor
struct OnboardingPipeline: View {
    @Environment(\.brutalistPalette) private var palette
    enum Active { case speech, ai }
    let active: Active

    var body: some View {
        HStack(spacing: 8) {
            Text("voice")
            arrow
            box("Speech model · Parakeet", on: active == .speech)
            arrow
            Text("text")
            arrow
            box("AI · optional", on: active == .ai)
            arrow
            Text("cleaned notes & answers")
        }
        .font(BrutalistTypography.mono11)
        .foregroundStyle(palette.fgMuted.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.bgCard.color))
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
        )
        .padding(.bottom, 18)
    }

    private var arrow: some View {
        Text("→").foregroundStyle(palette.accentBg.color)
    }

    private func box(_ text: String, on: Bool) -> some View {
        Text(text)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(on ? palette.fg.color : palette.fgSidebar.color)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? palette.highlightMatch.color : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(
                    on ? palette.primary.color : palette.borderSoft.color, lineWidth: 1))
    }
}

// MARK: - Selectable option card (speech + AI steps)

@MainActor
struct OptionCard<Body: View>: View {
    @Environment(\.brutalistPalette) private var palette
    let selected: Bool
    let title: String
    let badge: (text: String, primary: Bool)?
    let desc: String
    let onTap: () -> Void
    @ViewBuilder var expanded: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().stroke(selected ? palette.primary.color : palette.accentBg.color, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if selected {
                        Circle().fill(palette.primary.color).frame(width: 8, height: 8)
                    }
                }
                Text(title)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                if let badge {
                    Text(badge.text)
                        .font(BrutalistTypography.captionEmphasis)
                        .foregroundStyle(badge.primary ? palette.primary.color : palette.fgMuted.color)
                }
            }
            Text(desc)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 27)
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                expanded
                    .padding(.leading, 27)
                    .padding(.top, 13)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(selected ? palette.highlightMatch.color : palette.bgCard.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(
                selected ? palette.primary.color : palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - 3. Speech → text

@MainActor
struct OnboardingSpeechView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Bindable var state: OnboardingStateModel
    @Bindable var appState: AppStateModel

    private var install: AsrModelInstallCoordinator { state.asrInstall }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Speech → text")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
                .padding(.bottom, 16)
            OnboardingPipeline(active: .speech)
            Text(
                "This is the model that hears your voice and writes it down. Transcription only. (The AI that polishes and summarizes that text is the next step, and it's a different model.) Pick your on-device engine:"
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.bottom, 18)
            .frame(maxWidth: 640, alignment: .leading)

            OptionCard(
                selected: state.speechEngine == .parakeet,
                title: "Parakeet TDT v3 (best quality)",
                badge: ("Recommended", true),
                desc: "On-device, 25 languages, Apple Neural Engine. One-time ~700 MB download, then fully offline.",
                onTap: { selectEngine(.parakeet) }
            ) { EmptyView() }
            .padding(.bottom, 10)

            OptionCard(
                selected: state.speechEngine == .appleSpeech,
                title: "Apple Speech (instant, built-in)",
                badge: nil,
                desc:
                    "No download, works right now. Lower accuracy and fewer languages than Parakeet. Uses the Speech Recognition permission.",
                onTap: { selectEngine(.appleSpeech) }
            ) { EmptyView() }

            Spacer().frame(height: 18)

            if state.speechEngine == .appleSpeech {
                appleSpeechBlock
            } else {
                parakeetBlock
            }
        }
        .task { await install.probeReadiness() }
    }

    private func selectEngine(_ engine: OnboardingStateModel.SpeechEngine) {
        // Synchronous state mutation in the action — executor bug.
        state.speechEngine = engine
        switch engine {
        case .parakeet:
            appState.dictationASREngine = .parakeet
            appState.meetingASREngine = .parakeet
        case .appleSpeech:
            appState.dictationASREngine = .appleSpeech
            appState.meetingASREngine = .appleSpeech
        }
    }

    private var appleSpeechBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(BrutalistPalette.semantic(scheme).success.color).frame(width: 7, height: 7)
                Text("Apple Speech is ready. Nothing to download.")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(BrutalistPalette.semantic(scheme).success.color)
            }
            Text(
                "Uses the Speech Recognition permission · switch to Parakeet anytime in Settings → Dictation Models for higher accuracy and more languages."
            )
            .font(BrutalistTypography.caption)
            .foregroundStyle(palette.fgMuted.color)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var parakeetBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            cta.padding(.bottom, 14)
            OnboardingCard {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.fgSidebar.color)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.secondary.color))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Parakeet TDT v3 · multilingual")
                            .font(BrutalistTypography.labelEmphasis)
                            .foregroundStyle(palette.fg.color)
                        Text("25 languages · runs on the Apple Neural Engine")
                            .font(BrutalistTypography.caption)
                            .foregroundStyle(palette.fgMuted.color)
                    }
                    Spacer()
                    Text(rowStatus)
                        .font(BrutalistTypography.mono11)
                        .foregroundStyle(rowStatusColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
            totalStrip.padding(.vertical, 18)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Where it lives")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fgMuted.color)
                Text("~/Library/Application Support/FluidAudio/Models/")
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fgSidebar.color)
            }
            .padding(.horizontal, 4)
            OnboardingSkipNote(
                "Skip the download and your first ⌥Space waits while it fetches, or pick Apple Speech above to start instantly."
            )
        }
    }

    @ViewBuilder
    private var cta: some View {
        if install.parakeetReady {
            HStack(spacing: 8) {
                Circle().fill(BrutalistPalette.semantic(scheme).success.color).frame(width: 7, height: 7)
                Text("Downloaded and ready. Runs fully offline.")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(BrutalistPalette.semantic(scheme).success.color)
            }
        } else if install.isDownloading {
            Text("↓ Downloading… you can continue; it keeps running in the background.")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        } else if install.didFail {
            HStack(spacing: 12) {
                Text("Download didn't finish.")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.primary.color)
                BrutalistButton("Retry download", kind: .primary) { install.start() }
            }
        } else {
            BrutalistButton("Download Parakeet · ~700 MB", kind: .primary) { install.start() }
        }
    }

    private var rowStatus: String {
        if install.parakeetReady { return "ready" }
        if install.isDownloading { return "\(Int(install.parakeetFraction * 100))%" }
        return "queued"
    }
    private var rowStatusColor: Color {
        if install.parakeetReady { return BrutalistPalette.semantic(scheme).success.color }
        if install.isDownloading { return palette.primary.color }
        return palette.fgMuted.color
    }

    private var totalStrip: some View {
        HStack(spacing: 18) {
            Text("Total")
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.accentBg.color)
                    Capsule().fill(palette.primary.color)
                        .frame(width: proxy.size.width * (install.parakeetReady ? 1 : install.totalFraction), height: 5)
                }
                .frame(height: 5)
            }
            .frame(height: 5)
            Text(totalLabel)
                .font(BrutalistTypography.mono12)
                .foregroundStyle(palette.primary.color)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 4)
    }

    private var totalLabel: String {
        let pct = install.parakeetReady ? 1.0 : install.totalFraction
        return "\(Int(700 * pct)).0 MB / 700 MB"
    }
}

// MARK: - 4. AI for your text

@MainActor
struct OnboardingAIView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Bindable var state: OnboardingStateModel
    @Bindable var appState: AppStateModel
    @State private var verifyStatus = ""

    private let providers: [ModelProvider] = [.openRouter, .anthropic, .chatgpt, .minimax]

    private var isOff: Bool {
        if case .off = state.aiMode { return true }
        return false
    }
    private var isCloud: Bool {
        if case .cloud = state.aiMode { return true }
        return false
    }
    private var isAppleFM: Bool {
        if case .appleFM = state.aiMode { return true }
        return false
    }
    private var isOllama: Bool {
        if case .ollama = state.aiMode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AI for your text")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
                .padding(.bottom, 16)
            OnboardingPipeline(active: .ai)
            Text(
                "After Parakeet turns your voice into text, an optional AI layer can clean up dictation, write meeting summaries, answer questions across your library, and power the coach. It's off by default: no LLM calls, no cost, and nothing leaves your Mac until you turn it on. Choose what runs it when you do:"
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.bottom, 18)
            .frame(maxWidth: 640, alignment: .leading)

            OptionCard(
                selected: isOff,
                title: "Off (no AI)",
                badge: ("Default", false),
                desc:
                    "Great for most people. Dictation gets light, predictable clean-up (capitalisation and punctuation, no rewriting); meetings give you the raw transcript. Zero LLM calls, zero cost, fully private. Turn AI on here or in Settings anytime.",
                onTap: { apply(.off) }
            ) { EmptyView() }
            .padding(.bottom, 10)

            OptionCard(
                selected: isCloud,
                title: "Cloud model",
                badge: ("Recommended", true),
                desc:
                    "Better cleanup, summaries, and answers with your own key. Defaults to a fast, low-cost model (Gemini 3.1 Flash Lite via OpenRouter). Swap it for a bigger one anytime.",
                onTap: { apply(.cloud(.openRouter)) }
            ) { cloudBody }
            .padding(.bottom, 10)

            OptionCard(
                selected: isAppleFM,
                title: "On-device Apple Foundation Models",
                badge: nil,
                desc:
                    "Private and free, runs offline. Lighter quality than a cloud model; needs macOS Apple Intelligence enabled.",
                onTap: { apply(.appleFM) }
            ) { EmptyView() }
            .padding(.bottom, 10)

            OptionCard(
                selected: isOllama,
                title: "Local Ollama",
                badge: nil,
                desc: "Bigger local models, still fully private. Trace auto-detects what's installed.",
                onTap: { apply(.ollama) }
            ) { ollamaBody }

            OnboardingSkipNote(
                "Leave it Off and you get clean raw text with zero AI. Turn it on anytime in Settings → Intelligence, where you can also route individual tasks (cleanup, notes, Q&A, coach) to different models."
            )
        }
    }

    private func apply(_ mode: AppStateModel.AIMode) {
        // Synchronous: set selection + push it into the real settings now.
        state.aiMode = mode
        verifyStatus = ""
        if case .cloud(let provider) = mode, let mp = ModelProvider(rawValue: provider.rawValue) {
            state.cloudProvider = mp
        }
        appState.applyAIMode(mode)
    }

    private func selectProvider(_ provider: ModelProvider) {
        state.cloudProvider = provider
        verifyStatus = ""
        if let cleanup = DictationCleanupProvider(rawValue: provider.rawValue) {
            appState.applyAIMode(.cloud(cleanup))
        }
    }

    private var cloudModelLabel: String {
        ModelProvider(rawValue: state.cloudProvider.rawValue)?.defaultModel ?? ""
    }

    @ViewBuilder
    private var cloudBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(providers, id: \.self) { p in
                    Text(providerTab(p))
                        .font(BrutalistTypography.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(state.cloudProvider == p ? palette.fg.color : palette.fgMuted.color)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(
                                state.cloudProvider == p ? palette.highlightMatch.color : palette.secondary.color)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(
                                state.cloudProvider == p ? palette.primary.color : palette.borderSoft.color,
                                lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selectProvider(p) }
                }
            }
            // Reuse the real Settings credential card for the selected provider so
            // onboarding and Settings can never drift. ChatGPT = OAuth; the rest
            // are BYOK key cards (each posts .traceProvidersChanged on save).
            credentialCard
            Text(verifyStatus.isEmpty ? "We test the key before saving, so you know it works." : verifyStatus)
                .font(BrutalistTypography.caption)
                .foregroundStyle(
                    verifyStatus.hasPrefix("✓")
                        ? BrutalistPalette.semantic(scheme).success.color : palette.fgMuted.color)
            Text(
                {
                    var base = AttributedString("Model auto-set to ")
                    base.font = BrutalistTypography.caption
                    base.foregroundColor = palette.fgMuted.color
                    var model = AttributedString(cloudModelLabel)
                    model.font = BrutalistTypography.mono11
                    model.foregroundColor = palette.fgSidebar.color
                    var rest = AttributedString(
                        ". No need to pick one. Change it (and route each task separately) in Settings → Intelligence.")
                    rest.font = BrutalistTypography.caption
                    rest.foregroundColor = palette.fgMuted.color
                    return base + model + rest
                }())
        }
    }

    // The Settings credential cards (ProvidersSettingsView / ProviderKeyCard) are
    // SettingsGroup-styled with a built-in 32pt inset; a small negative inset
    // re-aligns them to the option-card body width.
    @ViewBuilder
    private var credentialCard: some View {
        Group {
            switch state.cloudProvider {
            case .chatgpt:
                OnboardingChatGPTCard()
            case .anthropic:
                ProviderKeyCard(provider: .anthropic, logo: .anthropic)
            case .minimax:
                ProviderKeyCard(provider: .minimax)
            default:
                ProviderKeyCard(
                    title: "OpenRouter",
                    hint: "One key fans out to GPT-5, Claude, Gemini, Mistral, DeepSeek, and many others.",
                    placeholder: "sk-or-…",
                    account: ModelProvider.openRouter.keychainAccount ?? "openrouter",
                    logo: .openRouter
                )
            }
        }
        .padding(.horizontal, -28)
    }

    @ViewBuilder
    private var ollamaBody: some View {
        if state.ollama?.reachable == true {
            HStack(spacing: 6) {
                Circle().fill(BrutalistPalette.semantic(scheme).success.color).frame(width: 6, height: 6)
                Text("Connected at localhost:11434 · \(state.ollama?.models.count ?? 0) model(s) loaded.")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(palette.primary.color).frame(width: 6, height: 6)
                Text("Ollama not detected at localhost:11434. Install it and Trace connects automatically.")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            }
        }
    }

    private func providerTab(_ p: ModelProvider) -> String {
        switch p {
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .chatgpt: return "ChatGPT"
        case .minimax: return "MiniMax"
        default: return p.displayName
        }
    }
}

/// ChatGPT (Codex) OAuth sign-in for the onboarding AI step — mirrors the
/// ProvidersSettingsView ChatGPT card (system-browser OAuth via CodexSignInFlow,
/// no key to paste), scoped to just this provider.
@MainActor
struct OnboardingChatGPTCard: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @State private var signedIn = false
    @State private var account: String?
    @State private var status = ""
    @State private var signingIn = false

    var body: some View {
        HStack(spacing: 8) {
            if signedIn {
                HStack(spacing: 6) {
                    Circle().fill(BrutalistPalette.semantic(scheme).success.color).frame(width: 6, height: 6)
                    Text(account.map { "Connected · \($0)" } ?? "Connected via your ChatGPT subscription.")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
                Spacer()
                BrutalistButton("Sign out", kind: .ghost) { Task { await signOut() } }
            } else {
                BrutalistButton(signingIn ? "Waiting for browser…" : "Sign in with ChatGPT…", kind: .primary) {
                    startSignIn()
                }
                .disabled(signingIn)
                Text(status.isEmpty ? "Sign in through your browser — no key to paste." : status)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(status.hasPrefix("Sign-in failed") ? palette.primary.color : palette.fgMuted.color)
                Spacer()
            }
        }
        .task {
            let credential = try? await OAuthTokenStore(account: CodexAuth.keychainAccount).current()
            signedIn = credential != nil
            account = credential?.accountId
        }
    }

    private func startSignIn() {
        guard !signingIn else { return }
        signingIn = true
        status = ""
        Task { @MainActor in
            do {
                let credential = try await CodexSignInFlow().signIn(openURL: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                })
                signedIn = true
                account = credential.accountId
                NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
            } catch {
                status = "Sign-in failed: \(error.localizedDescription)"
            }
            signingIn = false
        }
    }

    private func signOut() async {
        try? await OAuthTokenStore(account: CodexAuth.keychainAccount).clear()
        signedIn = false
        account = nil
        NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
    }
}

// MARK: - 5. Shortcuts (editable, real HotkeyRecorder)

@MainActor
struct OnboardingShortcutsView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var appState: AppStateModel
    @State private var activeRecorder: String?

    private struct Row: Identifiable {
        let action: HotkeyAction
        let name: String
        let desc: String
        var id: String { action.rawValue }
    }

    private let rows: [Row] = [
        Row(
            action: .dictationToggle, name: "Start / stop dictation",
            desc: "Push-to-talk: text lands at the cursor. Tip: press a key combo, or hold a lone right ⌘/⌥/⌃."),
        Row(
            action: .meetingToggle, name: "Start / stop meeting",
            desc: "Capture a call manually (auto-detect is in Settings)."),
        Row(
            action: .voiceMemoToggle, name: "Voice memo",
            desc: "Quick hands-free capture from anywhere."),
        Row(
            action: .transcribeFile, name: "Transcribe a file",
            desc: "Send the selected audio file to transcription."),
        Row(
            action: .openLibrary, name: "Open the library",
            desc: "Inbox, meetings, files, playbooks, settings."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shortcuts")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text(
                "These global hotkeys work from any app. Keep the defaults, or rebind any of them right now: click Edit and press your combo. Dictation can also be a lone right ⌘/⌥/⌃ held down (push-to-talk). The dictation one is what you'll use on the next step."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.vertical, 16)
            .frame(maxWidth: 640, alignment: .leading)

            OnboardingCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    keyRow(row)
                    if idx < rows.count - 1 { onboardingDivider(palette) }
                }
            }

            BrutalistButton("Reset to defaults", kind: .ghost) {
                var defaults: [String: HotkeyDescriptor] = [:]
                for r in rows { defaults[r.action.rawValue] = r.action.defaultDescriptor }
                appState.hotkeyBindings = defaults
                activeRecorder = nil
            }
            .padding(.top, 14)

            OnboardingSkipNote(
                "Skip and you keep the defaults shown above. Every shortcut is also editable later in Settings → Hotkeys."
            )
        }
    }

    private func keyRow(_ row: Row) -> some View {
        let descriptor = appState.descriptor(for: row.action.rawValue, default: row.action.defaultDescriptor)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Text(row.desc)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HotkeyRecorder(
                id: row.action.rawValue,
                descriptor: descriptor,
                activeID: $activeRecorder,
                allowsModifierTap: row.action == .dictationToggle
            ) { newDescriptor in
                var next = appState.hotkeyBindings
                next[row.action.rawValue] = newDescriptor
                appState.hotkeyBindings = next
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - 6. Try it (real dictation runtime)

@MainActor
struct OnboardingTryView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var state: OnboardingStateModel
    @Bindable var appState: AppStateModel
    @FocusState private var fieldFocused: Bool
    @State private var practiceText = ""
    @State private var listening = false

    private var install: AsrModelInstallCoordinator { state.asrInstall }

    /// Parakeet selected but not yet on disk → the practice falls back to Apple
    /// Speech so it never just spins.
    private var usingFallback: Bool {
        state.speechEngine == .parakeet && !install.parakeetReady
    }
    private var engineName: String {
        (state.speechEngine == .appleSpeech || usingFallback) ? "Apple Speech" : "Parakeet"
    }
    private var hotkeyLabel: String {
        HotkeyFormatter.display(
            appState.descriptor(
                for: HotkeyAction.dictationToggle.rawValue, default: HotkeyAction.dictationToggle.defaultDescriptor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Try dictation")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text(
                "Let's do one for real. Click the box, hold \(hotkeyLabel), say something, and let go. Your words appear, cleaned up. This is exactly how it works everywhere on your Mac."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .padding(.vertical, 16)
            .frame(maxWidth: 640, alignment: .leading)

            if usingFallback {
                Text(
                    "⚠ Parakeet isn't downloaded yet, so this practice runs on Apple Speech and you can try right now. Parakeet takes over automatically once it finishes."
                )
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgSidebar.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            }

            HStack(spacing: 10) {
                stepChip("1", "Click the box")
                stepChip("2", "Hold \(hotkeyLabel)")
                stepChip("3", "Speak")
                stepChip("4", "Let go")
            }
            .padding(.bottom, 18)

            TextField("Click here, then hold \(hotkeyLabel) and speak…", text: $practiceText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fg.color)
                .focused($fieldFocused)
                .lineLimit(3...6)
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.bgCard.color))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(
                        palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline))

            HStack(spacing: 14) {
                holdToTalk
                Text("Transcribing with \(engineName) · rebind on the previous step or in Settings → Hotkeys.")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)

            OnboardingSkipNote("Don't want to try now? Skip. The shortcut works everywhere the moment you finish.")
        }
        .task {
            await install.probeReadiness()
            // Ensure the dictation runtime uses an engine that's ready right now.
            if usingFallback { appState.dictationASREngine = .appleSpeech }
        }
        .onAppear { fieldFocused = true }
    }

    private func stepChip(_ num: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(num)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.fg.color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(palette.secondary.color))
            Text(label)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgCard.color))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline))
    }

    private var holdToTalk: some View {
        // Press = start real dictation; release = stop. The real runtime pastes
        // the transcript at the cursor, which is the focused practice field.
        HStack(spacing: 10) {
            Circle().fill(listening ? palette.primary.color : palette.fgMuted.color).frame(width: 9, height: 9)
            Text(listening ? "Listening… speak now" : "Hold to talk")
                .font(BrutalistTypography.label)
                .foregroundStyle(palette.fg.color)
            Text(hotkeyLabel)
                .font(BrutalistTypography.mono11)
                .foregroundStyle(palette.fg.color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(palette.secondary.color))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(listening ? palette.highlightMatch.color : palette.secondary.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(
                listening ? palette.primary.color : palette.border.color, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !listening {
                        listening = true
                        fieldFocused = true
                        NotificationCenter.default.post(name: .traceStartDictation, object: nil)
                    }
                }
                .onEnded { _ in
                    listening = false
                    NotificationCenter.default.post(name: .traceStopDictation, object: nil)
                }
        )
    }
}

// MARK: - 7. Done

@MainActor
struct OnboardingDoneView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var state: OnboardingStateModel
    @Bindable var appState: AppStateModel

    private var install: AsrModelInstallCoordinator { state.asrInstall }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primary.color)
                Text("Setup complete")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.primary.color)
            }
            .padding(.bottom, 18)

            Text("You're all set")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
                .padding(.bottom, 12)
            Text(
                "Trace lives in your menu bar. Here's where you landed. Everything below is changeable in Settings whenever you like."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .frame(maxWidth: 580, alignment: .leading)
            .padding(.bottom, 24)

            OnboardingCard {
                quick(
                    icon: "mic.circle", name: "Dictate anywhere", binding: hk(.dictationToggle),
                    desc: "Hold, talk, release, and text appears at your cursor.")
                onboardingDivider(palette)
                quick(
                    icon: "person.2.wave.2", name: "Capture a meeting", binding: hk(.meetingToggle),
                    desc: "Or let Trace auto-detect calls (enable in Settings).")
                onboardingDivider(palette)
                quick(
                    icon: "books.vertical", name: "Open your library", binding: hk(.openLibrary),
                    desc: "Everything you capture, searchable.")
            }
            .padding(.bottom, 24)

            Text("What's ready")
                .font(BrutalistTypography.groupTitle)
                .foregroundStyle(palette.fgMuted.color)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            bullet(modelLine)
            bullet(aiLine)
            bullet(
                "New captures land in your Inbox. Create projects anytime to organize them (no need to set one up now)."
            )
            bullet("Re-run this setup or grant skipped permissions anytime from the menu bar or Settings → About.")
        }
        .task { await install.probeReadiness() }
    }

    private func hk(_ action: HotkeyAction) -> String {
        HotkeyFormatter.display(appState.descriptor(for: action.rawValue, default: action.defaultDescriptor))
    }

    private var modelLine: String {
        if state.speechEngine == .appleSpeech {
            return "Speech: Apple Speech (built-in, no download)."
        }
        if install.parakeetReady { return "Speech: Parakeet ready, runs fully offline." }
        if install.isDownloading { return "Speech: Parakeet finishing in the background." }
        return "Speech: Parakeet downloads the first time you dictate (Apple Speech covers you until then)."
    }

    private var aiLine: String {
        switch state.aiMode {
        case .off: return "AI: off. Clean raw text, no LLM calls (turn on anytime)."
        case .cloud:
            let connected = ModelProvider(rawValue: state.cloudProvider.rawValue)?.isConnected() ?? false
            let name = providerName(state.cloudProvider)
            return connected ? "AI: on, \(name) connected." : "AI: on, \(name) selected (add a key to finish)."
        case .appleFM: return "AI: on, on-device Apple FM."
        case .ollama: return "AI: on, Ollama (connects when it's running)."
        }
    }

    private func providerName(_ p: ModelProvider) -> String {
        switch p {
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .chatgpt: return "ChatGPT"
        case .minimax: return "MiniMax"
        default: return p.displayName
        }
    }

    private func quick(icon: String, name: String, binding: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(palette.primary.color)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)
            HStack(spacing: 9) {
                Text(name)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Text(binding)
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fg.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.secondary.color))
            }
            .frame(width: 260, alignment: .leading)
            Text(desc)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(palette.primary.color)
            Text(text)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}

extension Color {
    init(hex: String) {
        let raw = hex.replacingOccurrences(of: "#", with: "")
        guard raw.count == 6 else {
            self = .clear
            return
        }
        let r = Int(raw.prefix(2), radix: 16) ?? 0
        let g = Int(raw.dropFirst(2).prefix(2), radix: 16) ?? 0
        let b = Int(raw.dropFirst(4).prefix(2), radix: 16) ?? 0
        self = Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }
}
