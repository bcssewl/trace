import AppKit
import DynamicNotchKit
import Foundation
import SwiftUI

@MainActor
public final class NotchHUDController {

    public enum HUDState: Sendable, Hashable {
        case hidden
        case compact
        case wide
        case dropdown
    }

    public let palette: BrutalistPalette.Pair
    public private(set) var hudState: HUDState = .hidden
    public var state = NotchHUDStateModel()

    private var notch: DynamicNotch<AnyView, AnyView, AnyView>?

    public init(palette: BrutalistPalette.Pair) {
        self.palette = palette
        rebuildNotch()
    }

    private func rebuildNotch() {
        let palette = palette
        let state = state
        let notch = DynamicNotch<AnyView, AnyView, AnyView>(
            style: .auto,
            expanded: {
                AnyView(
                    NotchExpandedView(state: state)
                        .environment(\.brutalistPalette, palette.dark)
                )
            },
            compactLeading: {
                AnyView(
                    NotchCompactLeadingView(state: state)
                        .environment(\.brutalistPalette, palette.dark)
                )
            },
            compactTrailing: {
                AnyView(
                    NotchCompactTrailingView(state: state)
                        .environment(\.brutalistPalette, palette.dark)
                )
            }
        )
        self.notch = notch
    }

    public func showCompact(timer: String, kind: NotchKind) {
        // Only reset the session clock when transitioning from hidden → shown.
        // While the notch is already active (e.g. .listening → .transcribing →
        // .inserted), keep the original startedAt so the timer keeps counting
        // from the moment recording began instead of jumping back to 0:00.
        if state.startedAt == nil {
            state.startedAt = Date()
        }
        state.kind = kind
        state.modeChangedAt = Date()
        state.targetApp = nil
        state.vuLevel = 0
        state.partial = ""
        state.promptTitle = nil
        state.promptDetail = nil
        state.promptIcon = nil
        hudState = .compact
        Task { await notch?.compact() }
    }

    /// Update just the semantic kind without disturbing the timer.
    ///
    /// Use this when
    /// the session is ongoing (e.g. after stop, switching to .transcribing,
    /// then to .inserted / .failed / etc.) so the elapsed counter keeps
    /// running smoothly until `hide()`.
    public func setKind(_ kind: NotchKind) {
        state.kind = kind
        state.modeChangedAt = Date()
        hudState = .compact
    }

    public func showWide(targetApp: String?, vuLevel: Double) {
        state.targetApp = targetApp
        state.vuLevel = vuLevel
        hudState = .wide
        Task { await notch?.expand() }
    }

    public func showDropdown(targetApp: String?, partial: String) {
        state.targetApp = targetApp
        state.partial = partial
        hudState = .dropdown
        Task { await notch?.expand() }
    }

    public func updateLevel(_ level: Double) {
        // Low-pass the spiky raw mic level so the notch hump eases toward each
        // reading instead of snapping to it (the "glitchy" jitter). Light enough
        // (0.4) to stay responsive to your voice.
        state.vuLevel += (level - state.vuLevel) * 0.4
    }

    /// Feed an interim transcript while dictating.
    ///
    /// Expands the notch to the
    /// dropdown form on the first non-empty partial, then just updates the
    /// text reactively (no repeated expand animations).
    public func updatePartial(_ text: String) {
        state.partial = text
        guard !text.isEmpty, hudState != .dropdown else { return }
        hudState = .dropdown
        Task { await notch?.expand() }
    }

    /// Drop the notch with a "meeting detected — start notes?" prompt instead of
    /// auto-recording.
    ///
    /// Accept (Start button or ⌥M) starts the meeting; "Later"
    /// posts `.traceMeetingPromptDismiss`.
    public func showMeetingPrompt(
        title: String, detail: String?, icon: NSImage? = nil, kind: MeetingPromptKind = .start, duration: Double = 15
    ) {
        state.promptTitle = title
        state.promptDetail = detail
        state.promptIcon = icon
        state.promptKind = kind
        state.promptDuration = duration
        hudState = .dropdown
        Task { await notch?.expand() }
    }

    /// Clear the meeting-detected prompt (if showing) and hide the notch.
    public func dismissMeetingPrompt() {
        guard state.promptTitle != nil else { return }
        state.promptTitle = nil
        state.promptDetail = nil
        state.promptIcon = nil
        hide()
    }

    public func hide() {
        hudState = .hidden
        state.startedAt = nil
        state.partial = ""
        Task { await notch?.hide() }
    }
}

public enum MeetingPromptKind: Sendable, Hashable {
    case start  // "Call detected" — Take Notes / dismiss
    case end  // "Call ended" — Stop & save / keep recording
}

/// Which behavior the notch's EQ hump plays.
///
/// Listening = active capture
/// (reactive to voice); transcribing = the model working (a calm breathe);
/// inserting = the session resolving (a left-to-right drain). Derived from the
/// semantic `NotchKind`, NOT from any display string.
public enum NotchPhase: Sendable, Hashable { case listening, transcribing, inserting }

/// The semantic state of the notch session.
///
/// This is the SINGLE source of truth
/// for control logic — the hump animation (`phase`) and the optional trailing
/// label both derive from this enum, never from the human-readable display
/// text. Decoupling these means the on-screen copy can be rewritten freely
/// (sentence case, British English) without breaking any matching.
///
/// `displayLabel` is the free, human-facing sentence-case string; it is what the
/// user reads. The enum case is what the code branches on.
public enum NotchKind: Sendable, Hashable {
    case listening  // active dictation capture
    case meeting  // meeting capture
    case voiceMemo  // voice-memo capture
    case preparing  // first-run model build / warm-up
    case downloading(Int)  // model download, percent 0…100
    case transcribing  // batch engine working post-stop
    case cleaning  // streaming engine tidying post-stop
    case inserted  // text pasted into the target app
    case copied  // text copied to the clipboard (no paste)
    case noAudio  // nothing was captured
    case failed  // dictation finalize failed
    case downloadFailed  // model download failed
    case unavailable  // dictation runtime couldn't be built

    /// The hump behavior for this kind.
    ///
    /// Capture kinds listen (react to voice);
    /// the model-working kinds breathe; the session-resolving kinds drain.
    public var phase: NotchPhase {
        switch self {
        case .listening, .meeting, .voiceMemo:
            return .listening
        case .preparing, .downloading, .transcribing, .cleaning:
            return .transcribing
        case .inserted, .copied, .noAudio, .failed, .downloadFailed, .unavailable:
            return .inserting
        }
    }

    /// The human-facing label for the compact/expanded chrome.
    ///
    /// British, plain,
    /// sentence case. `nil` means the hump's motion conveys it on its own (the
    /// core listening / transcribing / cleaning / inserted / copied flow), so no
    /// text is drawn beside the hump in the compact trailing view.
    public var displayLabel: String {
        switch self {
        case .listening: return "Dictating"
        case .meeting: return "Meeting"
        case .voiceMemo: return "Voice memo"
        case .preparing: return "Getting ready…"
        case .downloading(let pct): return "Downloading… \(pct)%"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Tidying up…"
        case .inserted: return "Inserted"
        case .copied: return "Copied"
        case .noAudio: return "Didn't catch anything"
        case .failed: return "Something went wrong"
        case .downloadFailed: return "Couldn't download — try again"
        case .unavailable: return "Dictation isn't ready"
        }
    }

    /// The label drawn beside the hump in the compact trailing view — only for
    /// states the hump can't express on its own (download progress, errors,
    /// meeting / voice-memo).
    ///
    /// The core dictation flow (listening / transcribing /
    /// cleaning / inserted / copied) returns `nil` because the hump conveys it.
    public var trailingLabel: String? {
        switch self {
        case .listening, .transcribing, .cleaning, .inserted, .copied:
            return nil
        default:
            return displayLabel
        }
    }
}

@MainActor
@Observable
public final class NotchHUDStateModel {
    /// Session start time.
    ///
    /// The compact/expanded views read this and compute
    /// a live elapsed timer via TimelineView. `nil` means no active session.
    public var startedAt: Date?
    /// Optional frontmost-app label. `nil` means "don't show" — older builds
    /// defaulted this to "Mail" which leaked into every HUD render.
    public var targetApp: String?
    /// The semantic state of the session — the single source of control logic.
    ///
    /// The hump phase and trailing label derive from this, never from display
    /// text. Defaults to `.listening` (a plain dictation session).
    public var kind: NotchKind = .listening
    /// When `kind` last changed — times the one-shot drain.
    ///
    /// Stamped by the
    /// controller's `showCompact` / `setKind`.
    public var modeChangedAt: Date = .init()
    public var vuLevel: Double = 0
    public var partial: String = ""

    /// The hump phase for the current `kind` — pure delegation to the enum, so
    /// there's no string matching driving the animation.
    public var phase: NotchPhase { kind.phase }
    /// When `promptTitle` is non-nil, the notch shows a meeting prompt (title +
    /// detail + optional app icon) instead of the recording UI. `promptKind`
    /// selects which one: a "Call detected" start prompt or a "Call ended" prompt.
    public var promptTitle: String?
    public var promptDetail: String?
    public var promptIcon: NSImage?
    public var promptKind: MeetingPromptKind = .start
    public var promptDuration: Double = 15

    public init() {}
}

@MainActor
public struct NotchCompactLeadingView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable public var state: NotchHUDStateModel

    public init(state: NotchHUDStateModel) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            NotchPulsingDot(color: palette.primary.color, size: 7)
            if let start = state.startedAt {
                TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                    Text(elapsed(since: start, now: ctx.date))
                        .font(BrutalistTypography.mono11)
                        .foregroundStyle(palette.fg.color)
                }
            } else {
                Text("0:00")
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fg.color)
            }
        }
        .padding(.horizontal, 8)
        // Match the trailing side's width (hump 62 + 8+8 padding = 78) with the
        // dot+timer right-aligned (hugging the camera), so the pill extends the
        // same distance left and right of the notch instead of leaning right.
        .frame(width: 78, alignment: .trailing)
    }
}

@MainActor
public struct NotchCompactTrailingView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable public var state: NotchHUDStateModel

    public init(state: NotchHUDStateModel) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 7) {
            EQHumpView(
                level: state.vuLevel, phase: state.phase, modeChangedAt: state.modeChangedAt,
                color: palette.primary.color
            )
            .frame(width: 62, height: 16)
            if let label = state.kind.trailingLabel {
                Text(label)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fg.color.opacity(0.85))
            }
        }
        .padding(.horizontal, 8)
    }
}

@MainActor
public struct NotchExpandedView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable public var state: NotchHUDStateModel

    public init(state: NotchHUDStateModel) {
        self.state = state
    }

    public var body: some View {
        if let prompt = state.promptTitle {
            MeetingDetectPromptView(
                title: prompt, detail: state.promptDetail, icon: state.promptIcon, duration: state.promptDuration,
                kind: state.promptKind)
        } else {
            recordingBody
        }
    }

    private var recordingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NotchPulsingDot(color: palette.primary.color, size: 8)
                Text(state.kind.displayLabel)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fg.color)
                if let start = state.startedAt {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        Text(elapsed(since: start, now: ctx.date))
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                EQHumpView(
                    level: state.vuLevel, phase: state.phase, modeChangedAt: state.modeChangedAt,
                    color: palette.primary.color
                )
                .frame(width: 72, height: 16)
                if let targetApp = state.targetApp, !targetApp.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(targetApp)
                            .font(BrutalistTypography.caption)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            if !state.partial.isEmpty {
                // Bounded, auto-scrolling transcript. Without the height cap the
                // notch grows without limit as live text streams in, pushing the
                // timer/header off screen. Instead we cap it to ~5 lines: new
                // words auto-scroll into view at the bottom, and the user can
                // scroll up to review everything said so far.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(state.partial)
                                .font(BrutalistTypography.body)
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("notch.transcript.bottom")
                        }
                    }
                    .frame(maxHeight: 110)
                    .onChange(of: state.partial) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("notch.transcript.bottom", anchor: .bottom)
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                Spacer()
                Text("Press")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(.white.opacity(0.55))
                Text("⌥ Space")
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(.white.opacity(0.7))
                Text("to stop")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        // Fixed width so the transcript WRAPS to multiple lines instead of
        // stretching the notch across the whole screen. Combined with the
        // maxHeight + ScrollView above, long dictations cap at ~5 lines and
        // scroll instead of growing.
        .frame(width: 440, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The "Call detected · <app>" prompt the notch drops down on auto-detect.
///
/// Shows the detected app's icon + name, a Take Notes button, a ✕, and a faint
/// orange countdown line that depletes over `duration` (matching the
/// coordinator's auto-dismiss timer).
@MainActor
private struct MeetingDetectPromptView: View {
    @Environment(\.brutalistPalette) private var palette
    let title: String
    let detail: String?
    let icon: NSImage?
    let duration: Double
    let kind: MeetingPromptKind
    @State private var progress: Double = 1.0

    private var primaryLabel: String { kind == .end ? "Stop & save" : "Take Notes" }
    private var primaryNotification: Notification.Name { kind == .end ? .traceStopMeeting : .traceStartMeeting }
    private var dismissNotification: Notification.Name {
        kind == .end ? .traceMeetingEndPromptKeep : .traceMeetingPromptDismiss
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: dismissNotification, object: nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    NotchPulsingDot(color: palette.primary.color, size: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(BrutalistTypography.captionEmphasis)
                        .foregroundStyle(.white)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(BrutalistTypography.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 12)
                Button {
                    NotificationCenter.default.post(name: primaryNotification, object: nil)
                } label: {
                    Text(primaryLabel)
                        .font(BrutalistTypography.captionEmphasis)
                        .foregroundStyle(palette.background.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.primary.color))
                }
                .buttonStyle(.plain)
            }
            GeometryReader { geo in
                Rectangle()
                    .fill(palette.primary.color.opacity(0.55))
                    .frame(width: max(0, geo.size.width * progress), height: 2)
            }
            .frame(height: 2)
        }
        .frame(width: 440, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .onAppear {
            progress = 1.0
            withAnimation(.linear(duration: duration)) { progress = 0 }
        }
    }
}

@MainActor
private func elapsed(since start: Date, now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

@MainActor
struct NotchPulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var on: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// The EQ-hump waveform that replaced the vertical VU bars on the right of the
/// notch.
///
/// A filled equalizer curve in the brand orange, drawn with `Canvas` +
/// a `TimelineView` clock so it animates continuously: it reacts to `level`
/// while listening, breathes calmly while the model works, and drains
/// left-to-right — all the way to the bottom, leaving no baseline line — as the
/// session resolves. `phase` selects the behavior; `modeChangedAt` times the
/// drain. Ported 1:1 from the brainstorm preview (dev/notch-preview).
@MainActor
struct EQHumpView: View {
    let level: Double
    let phase: NotchPhase
    let modeChangedAt: Date
    let color: Color

    var body: some View {
        // 60 fps clock for fluid motion (tiny canvas — negligible cost).
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                guard w > 1, h > 1 else { return }
                let t = tl.date.timeIntervalSinceReferenceDate
                let elapsed = t - modeChangedAt.timeIntervalSinceReferenceDate
                let lv = max(0.08, min(1.0, level))

                // Sample the curve densely, then stroke a quadratic-smoothed path
                // through the samples — straight segments between sparse points
                // looked faceted/"glitchy".
                let step = max(1.0, w / 96)
                var pts: [CGPoint] = []
                var x = 0.0
                while x <= w {
                    pts.append(CGPoint(x: x, y: humpY(x / w, h: h, t: t, elapsed: elapsed, lv: lv)))
                    x += step
                }
                guard pts.count > 1 else { return }

                var path = Path()
                path.move(to: CGPoint(x: 0, y: h))
                path.addLine(to: pts[0])
                for i in 0..<(pts.count - 1) {
                    let a = pts[i]
                    let b = pts[i + 1]
                    path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                }
                path.addLine(to: pts[pts.count - 1])
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()

                // Transcribing holds a calm, steady hump and pulses its *brightness*
                // (a gentle flash, spine intensifying) rather than its height —
                // height-breathing read as bouncy on a quick transcribe. Other
                // phases use the steady gradient (faint base → full orange spine).
                let stops: [Gradient.Stop]
                if phase == .transcribing {
                    let pulse = 0.5 + 0.5 * sin(t * 2.2)  // 0…1, gentle ~3 s
                    stops = [
                        .init(color: color.opacity(0.08 + 0.10 * pulse), location: 0),
                        .init(color: color.opacity(0.55 + 0.45 * pulse), location: 1),
                    ]
                } else {
                    stops = [
                        .init(color: color.opacity(0.12), location: 0),
                        .init(color: color, location: 1),
                    ]
                }
                ctx.fill(
                    path,
                    with: .linearGradient(
                        Gradient(stops: stops),
                        startPoint: CGPoint(x: 0, y: h),
                        endPoint: CGPoint(x: 0, y: 0)
                    ))
            }
        }
    }

    /// y for a normalized x (`k` in 0…1). `env = sin(kπ)` tapers the curve to
    /// zero at both edges so it reads as a centered hump. `lv` is the (already
    /// low-passed) voice level for the listening phase.
    private func humpY(_ k: Double, h: Double, t: Double, elapsed: Double, lv: Double) -> Double {
        let env = sin(k * .pi)
        switch phase {
        case .listening:
            let amp = (0.5 + 0.5 * sin(k * 6 - t * 4) + 0.3 * sin(k * 13 - t * 6)) * 0.5
            return h - 2 - (amp * h * 0.78 * lv * env + env * 4)
        case .transcribing:
            // Steady, calm height (constant ~0.5 level) — the motion lives in the
            // brightness pulse in `body`, not the height, so it doesn't bounce.
            return h - 2 - (env * h * 0.25 + env * 4)
        case .inserting:
            let drain = min(1.0, max(0.0, elapsed / 0.85))
            if k < drain { return h }  // drained → flat bottom (no residual line)
            let a = (0.5 + 0.4 * sin(k * 7)) * 0.5
            return h - 2 - (a * h * 0.55 * env + env * 4)
        }
    }
}
