import AppKit
import CoachModule
import Foundation
import SwiftUI

@MainActor
public final class CoachOverlayController {
    private let panel: CoachPanel
    public let palette: BrutalistPalette.Pair
    public let state = CoachOverlayStateModel()

    /// UserDefaults key for the persisted panel frame (BAS redesign): the panel
    /// restores its last size/position instead of re-anchoring every present().
    private static let frameDefaultsKey = "trace.coach.overlay.frame"
    private var hasRestoredFrame = false
    private let keyMonitorBox = CoachKeyMonitorBox()

    /// The last mode we sized the panel for — so we only re-frame on an actual
    /// pill↔card transition, not on every observation tick.
    private var lastSizedMode: CoachOverlayMode?
    /// The pill-hover state we last sized for — so a hover toggle re-frames the pill
    /// even though `state.mode` itself didn't change.
    private var lastSizedPillHovered = false
    /// Set while the controller is programmatically setting the panel frame, so the
    /// frame-saver delegate doesn't persist our own pill/restore moves.
    private var isProgrammaticallyFraming = false

    public init(palette: BrutalistPalette.Pair) {
        self.palette = palette
        let frame = NSRect(
            x: 0, y: 0,
            width: BrutalistMetrics.coachWidth,
            height: BrutalistMetrics.coachDefaultHeight
        )
        self.panel = CoachPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        configurePanel()
        installRootView()
        panel.orderOut(nil)
        // The in-overlay "Hide" / dismiss posts this; minimize-to-pill on receipt.
        NotificationCenter.default.addObserver(
            forName: .traceCoachOverlayHide, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.minimizeToPill() }
        }
        installKeyMonitor()
        observeMode()
    }

    /// React to every `state.mode` change — whether the controller flips it
    /// (present/update/minimize) or the SwiftUI tree does (pill button, ask chip,
    /// header expand).
    ///
    /// On a pill↔card transition we re-frame the NSPanel so the
    /// content is never clipped into the wrong size. Re-arms after each fire.
    private func observeMode() {
        withObservationTracking {
            _ = state.mode
            // Also track pill-hover: hovering the collapsed pill grows its frame so
            // the revealed Ask chips aren't clipped, then shrinks it back on exit.
            _ = state.pillHovered
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncFrameToMode()
                self.observeMode()
            }
        }
    }

    deinit {
        keyMonitorBox.removeMonitor()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.styleMask.remove(.titled)
        panel.hasShadow = true
        // Drag from anywhere on the background — the most discoverable way to move
        // the panel. Controls (Ask chips, header buttons) consume their own clicks;
        // only the empty background initiates the window drag. Resize edges are
        // handled by the .resizable style mask and take priority at the border.
        panel.isMovableByWindowBackground = true
        // Min/max start permissive enough for the pill; `syncFrameToMode` tightens
        // them per mode (pill = fixed small, card = user-resizable within bounds).
        applyConstraints(forCard: false)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = BrutalistMetrics.coachCornerRadius
        panel.contentView?.layer?.masksToBounds = true
        // Persist the frame across resizes/moves.
        panel.delegate = frameSaver
    }

    private lazy var frameSaver = CoachFrameSaver(key: Self.frameDefaultsKey) { [weak self] in
        // Only persist a frame that represents a user-chosen CARD size — never the
        // fixed pill, and never our own programmatic restore/shrink moves.
        guard let self else { return false }
        return self.state.mode != .compact && !self.isProgrammaticallyFraming
    }

    /// Cancellable work item for the debounced pill-collapse on mouse-exit.
    ///
    /// Holding
    /// it lets a re-entry (the cursor catching up to the grown pill) cancel a
    /// pending collapse — the hysteresis that breaks the grow→exit→shrink→enter loop.
    private var pendingPillCollapse: DispatchWorkItem?
    /// Grace period after the cursor leaves the pill before it actually collapses.
    ///
    /// Long enough to outlast the grow animation re-settling under a still cursor.
    private static let pillCollapseDelay: TimeInterval = 0.18

    private func installRootView() {
        // A custom hosting view that owns a stable NSTrackingArea (see CoachHostingView).
        // We track hover on the real AppKit view bounds — which `.inVisibleRect`
        // keeps glued to the view as the window resizes — instead of a SwiftUI
        // `.onHover` whose reported bounds lag the animated frame change and
        // spuriously fire exit/enter, seizing the pill in an expand/collapse loop.
        let host = CoachHostingView(
            rootView: CoachOverlayRootView(palettePair: palette, state: state)
        )
        host.onHoverChange = { [weak self] entered in
            // AppKit tracking callbacks already land on the main thread; hop to the
            // MainActor to mutate the @Observable state safely.
            MainActor.assumeIsolated { self?.handlePillHover(entered: entered) }
        }
        // Don't let the SwiftUI content impose its min/intrinsic/max size as Auto
        // Layout constraints on this resizable panel. That feedback (content size
        // vs. the panel's own min/max) is what makes AppKit exceed its
        // "Update Constraints in Window" pass limit and raise the CoachPanel
        // NSException. The host simply fills + follows the panel instead.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        configurePanel()
    }

    /// Drive `state.pillHovered` from the AppKit tracking area with exit hysteresis.
    ///
    /// Enter reveals the Ask chips (and grows the pill) immediately and cancels any
    /// pending collapse; exit schedules a cancellable delayed collapse so a re-entry
    /// during the grow animation simply cancels it instead of toggling forever.
    private func handlePillHover(entered: Bool) {
        // Hover only matters while collapsed — the card has its own bottom Ask bar.
        guard state.mode == .compact else { return }
        if entered {
            pendingPillCollapse?.cancel()
            pendingPillCollapse = nil
            state.pillHovered = true
        } else {
            pendingPillCollapse?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingPillCollapse = nil
                if self.state.mode == .compact { self.state.pillHovered = false }
            }
            pendingPillCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pillCollapseDelay, execute: work)
        }
    }

    /// Show the panel, restoring its persisted frame on first present (no longer
    /// re-anchoring every call).
    ///
    /// The SwiftUI tree draws over a live
    /// NSVisualEffectView material so it stays legible over any call background.
    public func present(projectName: String = "Project") {
        state.projectName = projectName
        // Size the panel for the current mode before showing it (the observation
        // path only fires on subsequent *changes*, not the initial present).
        syncFrameToMode(force: !hasRestoredFrame)
        hasRestoredFrame = true
        panel.orderFrontRegardless()
    }

    public func update(activeCard: CoachCard?) {
        state.activeCard = activeCard
        // A real card surfaces the full cue card; a silent/empty result must NOT
        // pop an empty card — stay compact (behavioral fix).
        if let card = activeCard, card.mode != .silent, !card.isEmpty {
            state.mode = .card
            state.surfacedAt = Date()
        } else {
            // No useful card → collapse to listening pill (don't show empty card).
            if state.mode == .card { state.mode = .compact }
        }
    }

    public func update(conversationState: String) {
        state.conversationState = conversationState
    }

    public func appendRecentTrigger(_ trigger: RecentTrigger) {
        state.recentTriggers.insert(trigger, at: 0)
        if state.recentTriggers.count > 8 {
            state.recentTriggers.removeLast()
        }
    }

    public func hide() {
        panel.orderOut(nil)
    }

    /// Minimize to the compact pill rather than fully hiding — the coach keeps
    /// listening; the user can click the pill to bring the card back.
    public func minimizeToPill() {
        state.mode = .compact
        state.activeCard = nil
    }

    public func applyAppearance(_ preference: AppearancePreference) {
        switch preference.preferredScheme {
        case .some(.light): panel.appearance = NSAppearance(named: .aqua)
        case .some(.dark): panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil
        }
    }

    public var isWindowExcludedFromScreenShare: Bool {
        panel.sharingType == .none
    }

    /// Real ⌥esc dismiss hotkey (BAS redesign).
    ///
    /// A non-activating panel never holds
    /// key focus, so a local monitor catches it whenever Trace is frontmost; the
    /// global fallback handles it during a call when another app is frontmost.
    private func installKeyMonitor() {
        keyMonitorBox.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌥esc: option held + escape (keyCode 53).
            if event.keyCode == 53, event.modifierFlags.contains(.option) {
                MainActor.assumeIsolated { self?.minimizeToPill() }
                return nil
            }
            return event
        }
    }

    // MARK: Frame management (pill ↔ card)

    /// Resize the NSPanel to match `state.mode`.
    ///
    /// The pill is a fixed small size; the
    /// card restores the user's persisted/resizable frame. Both transitions keep the
    /// panel's top-right corner pinned so the card grows downward/leftward out of the
    /// pill (natural for a top-right overlay) instead of jumping.
    ///
    /// `force` re-frames even when the mode hasn't changed (used on first present, so
    /// the panel never opens at its stale default frame).
    private func syncFrameToMode(force: Bool = false) {
        let mode = state.mode
        let pillHovered = state.pillHovered
        // Re-frame on a mode change, a forced present, or — while compact — a
        // pill-hover toggle (which grows/shrinks the pill to fit the Ask chips).
        let pillHoverChanged = mode == .compact && pillHovered != lastSizedPillHovered
        guard force || mode != lastSizedMode || pillHoverChanged else { return }
        lastSizedMode = mode
        lastSizedPillHovered = pillHovered

        isProgrammaticallyFraming = true
        defer { isProgrammaticallyFraming = false }

        switch mode {
        case .compact:
            applyConstraints(forCard: false)
            frameToPill(hovered: pillHovered)
        case .card, .expanded:
            // Leaving the pill clears its hover sub-state so it resets to the small
            // chip next time it minimizes.
            state.pillHovered = false
            applyConstraints(forCard: true)
            frameToCard()
        }
    }

    /// Pill is fixed-size and non-resizable; pin its top-right corner to where the
    /// panel currently sits (so minimizing doesn't make it jump across the screen).
    private func frameToPill(hovered: Bool) {
        let size =
            hovered
            ? NSSize(
                width: BrutalistMetrics.coachPillHoverWidth,
                height: BrutalistMetrics.coachPillHoverHeight)
            : NSSize(
                width: BrutalistMetrics.coachPillWidth,
                height: BrutalistMetrics.coachPillHeight)
        let topRight = currentTopRight()
        var rect = NSRect(
            x: topRight.x - size.width, y: topRight.y - size.height,
            width: size.width, height: size.height)
        rect = Self.clampOnScreen(rect)
        // Animate the grow/shrink so the hover reveal feels smooth (no jump).
        panel.setFrame(rect, display: true, animate: true)
    }

    /// Card restores the persisted user-chosen frame if it's valid + on-screen,
    /// otherwise a sensible default anchored top-right out of the current corner.
    private func frameToCard() {
        let topRight = currentTopRight()
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey),
            !saved.isEmpty
        {
            let rect = NSRectFromString(saved)
            if rect.width >= BrutalistMetrics.coachMinWidth,
                rect.height >= BrutalistMetrics.coachMinHeight,
                Self.frameIsOnScreen(rect)
            {
                panel.setFrame(Self.clampOnScreen(rect), display: true, animate: false)
                return
            }
        }
        // Default card: grow down/left out of the current top-right corner.
        let size = NSSize(
            width: BrutalistMetrics.coachCardDefaultWidth,
            height: BrutalistMetrics.coachCardDefaultHeight)
        var rect = NSRect(
            x: topRight.x - size.width, y: topRight.y - size.height,
            width: size.width, height: size.height)
        rect = Self.clampOnScreen(rect)
        panel.setFrame(rect, display: true, animate: false)
    }

    /// The panel's current top-right corner if it has ever been placed; otherwise the
    /// default top-right anchor on the main screen.
    private func currentTopRight() -> NSPoint {
        if hasRestoredFrame, panel.frame.width > 1, panel.frame.height > 1 {
            return NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        }
        guard let screen = NSScreen.main else {
            return NSPoint(
                x: BrutalistMetrics.coachCardDefaultWidth + BrutalistMetrics.space3,
                y: BrutalistMetrics.coachCardDefaultHeight + BrutalistMetrics.coachTopInset)
        }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - BrutalistMetrics.space3,
            y: visible.maxY - BrutalistMetrics.coachTopInset)
    }

    /// Pill is fixed (min == max).
    ///
    /// Card is user-resizable within the coach bounds.
    private func applyConstraints(forCard: Bool) {
        if forCard {
            panel.minSize = NSSize(
                width: BrutalistMetrics.coachMinWidth,
                height: BrutalistMetrics.coachMinHeight)
            panel.maxSize = NSSize(
                width: BrutalistMetrics.coachMaxWidth,
                height: BrutalistMetrics.coachMaxHeight)
        } else {
            // Pill is non-user-resizable, but its allowed range must span both the
            // collapsed chip and the hovered (Ask-chips revealed) size so our own
            // animated grow/shrink isn't clamped.
            panel.minSize = NSSize(
                width: BrutalistMetrics.coachPillWidth,
                height: BrutalistMetrics.coachPillHeight)
            panel.maxSize = NSSize(
                width: BrutalistMetrics.coachPillHoverWidth,
                height: BrutalistMetrics.coachPillHoverHeight)
        }
    }

    /// Keep a frame fully within a connected screen's visible area.
    private static func clampOnScreen(_ rect: NSRect) -> NSRect {
        guard
            let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) })
                ?? NSScreen.main
        else { return rect }
        let visible = screen.visibleFrame
        var r = rect
        r.size.width = min(r.size.width, visible.width)
        r.size.height = min(r.size.height, visible.height)
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        if r.minY < visible.minY { r.origin.y = visible.minY }
        return r
    }

    /// True when the saved frame still overlaps a connected screen (so a panel
    /// saved on an unplugged monitor doesn't restore off-screen).
    private static func frameIsOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }
}

/// Holds the local key monitor so it can be removed from a nonisolated deinit
/// without crossing actor isolation on a non-Sendable value.
final class CoachKeyMonitorBox: @unchecked Sendable {
    var monitor: Any?
    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Persists the panel frame on resize/move so it restores instead of re-anchoring.
@MainActor
final class CoachFrameSaver: NSObject, NSWindowDelegate {
    private let key: String
    /// Returns true only when the current frame is a user-chosen CARD frame worth
    /// persisting (never the fixed pill, never a programmatic restore/shrink).
    private let shouldPersist: () -> Bool
    init(key: String, shouldPersist: @escaping () -> Bool) {
        self.key = key
        self.shouldPersist = shouldPersist
    }
    private func save(_ window: NSWindow) {
        guard shouldPersist() else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }
    func windowDidResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow { save(w) }
    }
    func windowDidMove(_ notification: Notification) {
        if let w = notification.object as? NSWindow { save(w) }
    }
}

/// Non-activating coach panel.
///
/// It never becomes key/main, so it never steals the
/// user's keyboard focus from the call app (the safe click-through tradeoff —
/// per-pixel mouse passthrough would break the panel's own buttons/resize/drag,
/// so we keep mouse events but never grab focus). A single click on the panel acts
/// on the panel without backgrounding the call.
final class CoachPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel's content view.
///
/// It owns a single NSTrackingArea covering its visible
/// rect so hover is measured against the REAL AppKit view bounds, not SwiftUI's lagged
/// view geometry. `.inVisibleRect` auto-resizes the tracking region as the window
/// grows/shrinks, so the pill's own grow animation never spuriously fires
/// exit/enter while the cursor stays inside — the root cause of the old flicker.
final class CoachHostingView<Content: View>: NSHostingView<Content> {
    /// Called on mouse enter (`true`) / exit (`false`).
    ///
    /// The controller debounces exit.
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        // `.inVisibleRect` makes AppKit recompute the region from `visibleRect` on
        // every layout, so the passed rect is a placeholder; the options carry the
        // behavior. `.activeAlways` tracks even though the panel never becomes key.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

public struct RecentTrigger: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let label: String
    public let mode: CoachCardMode
    public let wasSurfaced: Bool

    public init(id: UUID = UUID(), timestamp: Date = Date(), label: String, mode: CoachCardMode, wasSurfaced: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.label = label
        self.mode = mode
        self.wasSurfaced = wasSurfaced
    }
}

public enum CoachOverlayMode: Sendable {
    case compact
    case card
    case expanded
}

@MainActor
@Observable
public final class CoachOverlayStateModel {
    public var projectName: String = "—"
    public var activeCard: CoachCard?
    public var conversationState: String = ""
    public var recentTriggers: [RecentTrigger] = []
    /// Surface state: starts compact (listening pill) so a meeting never auto-pops
    /// a full panel; a real card flips it to `.card`.
    public var mode: CoachOverlayMode = .compact
    /// When the current passive card was surfaced — drives the auto-dismiss timer.
    public var surfacedAt: Date?
    /// True while the mouse hovers the collapsed pill — reveals the Ask chips and
    /// grows the pill frame to fit them (see `syncFrameToMode`/`observeMode`).
    public var pillHovered: Bool = false

    public init() {}
}

extension CoachCard {
    /// Whether the card has anything worth showing (lead, body, or points).
    ///
    /// A
    /// silent/empty routing result is `.isEmpty == true` and must not pop a card.
    var isEmpty: Bool {
        lead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && points.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The accented say-this line: `lead` when present, else the legacy `body`.
    var displayLead: String {
        let trimmed = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? body : lead
    }
}

@MainActor
struct CoachOverlayRootView: View {
    let palettePair: BrutalistPalette.Pair
    @Environment(\.colorScheme) private var scheme
    @Bindable var state: CoachOverlayStateModel

    @State private var leadExpanded = false
    @State private var hovering = false
    @State private var now = Date()

    /// Passive cards auto-dismiss after this many seconds (paused on hover).
    private static let autoDismissSeconds: TimeInterval = 12

    private var palette: BrutalistPalette { palettePair.resolve(scheme) }

    private let dismissTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch state.mode {
            case .compact:
                compactPill
            case .card, .expanded:
                fullPanel
            }
        }
        .background(
            CoachMaterialBackground(material: .hudWindow)
                .overlay(palette.background.color.opacity(scheme == .dark ? 0.18 : 0.10))
        )
        .environment(\.brutalistPalette, palette)
        .onHover { hovering = $0 }
        .onReceive(dismissTimer) { date in
            now = date
            tickAutoDismiss()
        }
    }

    // MARK: Auto-dismiss

    /// Auto-dismiss passive cards after the timeout (paused while hovered).
    ///
    /// Keeps
    /// interactive (pacing/agenda) cards until the user acts on them.
    private func tickAutoDismiss() {
        guard state.mode == .card, !hovering else { return }
        guard let card = state.activeCard, card.surface == .passive,
            let surfacedAt = state.surfacedAt
        else { return }
        if now.timeIntervalSince(surfacedAt) > Self.autoDismissSeconds {
            state.activeCard = nil
            state.mode = .compact
            state.surfacedAt = nil
        }
    }

    // MARK: Compact pill

    private var compactPill: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // Click the pill → expand to the last/current card if present, else
                // an idle listening header.
                state.mode = .card
            } label: {
                HStack(spacing: 9) {
                    BrutalistPulsingDot(color: palette.primary.color, size: 7)
                    Text("Coach")
                        .font(BrutalistTypography.labelEmphasis)
                        .foregroundStyle(palette.fg.color)
                    if !state.recentTriggers.isEmpty {
                        Text("\(state.recentTriggers.filter(\.wasSurfaced).count)")
                            .font(BrutalistTypography.captionEmphasis)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.primary.color))
                    }
                    if state.pillHovered {
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.fgMuted.color)
                            .help("Expand")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coachRoundedButton(radius: 0, palette: palette)
            // Ask chips only revealed on hover, so the resting pill is a tiny chip.
            if state.pillHovered {
                Rectangle().fill(palette.borderSoft.color).frame(height: 1)
                askBar
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // NOTE: the pill-hover sub-state is NOT driven by a SwiftUI `.onHover` here.
        // The controller installs a stable AppKit NSTrackingArea on the hosting view
        // (CoachHostingView) and drives `state.pillHovered` from mouseEntered/Exited
        // with exit hysteresis — that survives the frame-resize animation without the
        // grow→exit→shrink→enter flicker a SwiftUI `.onHover` on a resizing view causes.
    }

    // MARK: Ask bar (directed "Ask the coach" requests)

    /// The four directed-request chips — always one tap away in both the compact
    /// pill and the bottom of the card.
    ///
    /// Each posts a `CoachIntent` that bypasses the
    /// detection gates and steers the prompt.
    private var askBar: some View {
        HStack(spacing: 6) {
            Text("Ask:")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
            askChip("Answer", intent: .answer)
            askChip("Reframe", intent: .reframe)
            askChip("Sound smart", intent: .soundSmart)
            askChip("Fact check", intent: .factCheck)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func askChip(_ title: String, intent: CoachIntent) -> some View {
        Button {
            // Surface the card immediately (synchronous state mutation) and fire the
            // directed request; the runtime coordinator handles it off the main path.
            state.mode = .card
            NotificationCenter.default.post(name: .traceCoachAsk, object: intent)
        } label: {
            Text(title)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fg.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
                )
        }
        // Base accent fill + hover/press tint both clipped to the chip's rounding —
        // the static fill is the style's "rest" state so hover layers cleanly on top.
        .buttonStyle(
            CoachRoundedButtonStyle(
                cornerRadius: 8,
                hoverFill: palette.accentBg.color.opacity(0.8),
                pressFill: palette.accentBg.color
            )
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accentBg.color.opacity(0.5))
        )
        .help("Ask the coach to \(title.lowercased())")
    }

    // MARK: Full panel

    private var fullPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    cueSection
                    if state.mode == .expanded {
                        Rectangle().fill(palette.borderSoft.color).frame(height: 1)
                        detailsSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            // Ask bar pinned to the BOTTOM of the card, below the cue content (or the
            // listening placeholder when there's no active cue).
            askBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrutalistPulsingDot(color: palette.primary.color, size: 7)
            Text("Coach")
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            Text("· \(state.projectName)")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
            Spacer()
            iconButton(
                systemName: state.mode == .expanded ? "chevron.up" : "slider.horizontal.3",
                help: "Details"
            ) {
                state.mode = state.mode == .expanded ? .card : .expanded
            }
            iconButton(systemName: "minus", help: "Minimize") {
                NotificationCenter.default.post(name: .traceCoachOverlayHide, object: nil)
            }
            iconButton(systemName: "xmark", help: "Dismiss (⌥esc)") {
                NotificationCenter.default.post(name: .traceCoachOverlayHide, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Whole panel is drag-anywhere (isMovableByWindowBackground); the header's
        // own buttons still consume their clicks, so no explicit drag region needed.
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.fgMuted.color)
                .frame(width: 24, height: 24)
        }
        .coachRoundedButton(radius: 6, palette: palette)
        .help(help)
    }

    // MARK: Cue card

    @ViewBuilder
    private var cueSection: some View {
        if let card = state.activeCard, !card.isEmpty {
            cueCard(card)
        } else {
            listeningRow
        }
    }

    private func cueCard(_ card: CoachCard) -> some View {
        let trust = Self.trustBadge(for: card.mode)
        return VStack(alignment: .leading, spacing: 9) {
            // mode badge — one restrained per-mode dot, not everything orange
            HStack(spacing: 6) {
                Circle().fill(Self.modeColor(card.mode, scheme: scheme, palette: palette)).frame(width: 6, height: 6)
                Text(trust.label)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fgMuted.color)
                Spacer()
            }
            // context (what they asked)
            if !card.title.isEmpty {
                Text(card.title)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // the single accented say-this line, clamps with Show more
            leadView(card)
            // supporting bullets
            if !card.points.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(card.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 8) {
                            Text("›")
                                .font(BrutalistTypography.labelEmphasis)
                                .foregroundStyle(palette.primary.color)
                            Text(point)
                                .font(BrutalistTypography.body)
                                .foregroundStyle(palette.fg.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            // source / trust line
            sourceRow(card, grounded: trust.grounded)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The accented "say this" line with a left-rule.
    ///
    /// Long leads clamp to a few
    /// lines and reveal a Show more / Show less toggle.
    @ViewBuilder
    private func leadView(_ card: CoachCard) -> some View {
        let text = card.displayLead
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(palette.primary.color).frame(width: 2)
                    Text(text)
                        .font(BrutalistTypography.sectionHeader)
                        .foregroundStyle(palette.fg.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(leadExpanded ? nil : 4)
                        .padding(.leading, 11)
                }
                if text.count > 160 {
                    Button(leadExpanded ? "Show less" : "Show more") {
                        leadExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.primary.color)
                    .padding(.leading, 13)
                }
            }
        }
    }

    private func sourceRow(_ card: CoachCard, grounded: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: grounded ? "doc.text.magnifyingglass" : "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(grounded ? palette.fgMuted.color : palette.fgSidebar.color.opacity(0.7))
            Text(sourceLabel(for: card, grounded: grounded))
                .font(BrutalistTypography.caption)
                .foregroundStyle(grounded ? palette.fgMuted.color : palette.fgSidebar.color.opacity(0.7))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.top, 1)
        // Ungrounded "general knowledge" reads visibly lower-key than a grounded
        // doc source (trust gradient).
        .opacity(grounded ? 1 : 0.85)
    }

    private var listeningRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.fgMuted.color)
            Text("Listening… cues appear when something useful comes up.")
                .font(BrutalistTypography.label)
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Details (progressive disclosure)

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            conversationStateRow
            recentLog
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var conversationStateRow: some View {
        if !state.conversationState.isEmpty {
            HStack(spacing: 7) {
                Circle().fill(palette.primary.color).frame(width: 5, height: 5)
                Text(state.conversationState)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fg.color)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    private var recentLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent cues")
                    .font(BrutalistTypography.groupTitle)
                    .foregroundStyle(palette.fgMuted.color)
                Spacer()
                let surfaced = state.recentTriggers.filter(\.wasSurfaced).count
                Text("\(surfaced) surfaced · \(state.recentTriggers.count) detected")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            }
            ForEach(state.recentTriggers) { trigger in
                HStack(spacing: 8) {
                    Circle()
                        .fill(trigger.wasSurfaced ? palette.primary.color : palette.accentBg.color)
                        .frame(width: 5, height: 5)
                    Text(trigger.label)
                        .font(BrutalistTypography.label)
                        .foregroundStyle(trigger.wasSurfaced ? palette.fg.color : palette.fgSidebar.color)
                        .lineLimit(1)
                    Spacer()
                    Text(trigger.mode.rawValue.capitalized)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Trust + mode treatment

    private static func trustBadge(for mode: CoachCardMode) -> (label: String, grounded: Bool) {
        switch mode {
        case .grounded: return ("From your docs", true)
        case .synthesized: return ("From your playbook", true)
        case .general: return ("General AI", false)
        case .reframe: return ("A nudge", false)
        case .agenda: return ("Agenda", false)
        case .silent: return ("—", false)
        }
    }

    /// One restrained per-mode accent dot (not everything orange).
    ///
    /// Pulls from the
    /// shared semantic palette so green/blue/amber read correctly in both schemes.
    private static func modeColor(_ mode: CoachCardMode, scheme: ColorScheme, palette: BrutalistPalette) -> Color {
        let semantic = BrutalistPalette.semantic(scheme)
        switch mode {
        case .grounded, .synthesized: return semantic.success.color  // green = grounded
        case .general: return semantic.info.color  // blue = AI
        case .reframe: return semantic.warning.color  // amber = nudge
        case .agenda: return semantic.info.color
        case .silent: return palette.fgMuted.color
        }
    }

    private func sourceLabel(for card: CoachCard, grounded: Bool) -> String {
        let trimmed = card.attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return grounded ? "From your playbook" : "General knowledge"
    }
}

/// A plain button style whose hover/press highlight is a rounded-rectangle fill
/// clipped to `cornerRadius` — replacing the default macOS button highlight, which
/// draws a SHARP-cornered rectangle that bleeds past the panel/card rounding.
struct CoachRoundedButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var hoverFill: Color
    var pressFill: Color

    func makeBody(configuration: Configuration) -> some View {
        // The hover state lives in a dedicated view so `@State` is reliably owned
        // per button instance (a ButtonStyle struct is a poor place for @State).
        Highlighted(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hoverFill: hoverFill,
            pressFill: pressFill)
    }

    private struct Highlighted: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let hoverFill: Color
        let pressFill: Color
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            return configuration.label
                .background(
                    shape.fill(
                        configuration.isPressed
                            ? pressFill
                            : (hovering ? hoverFill : Color.clear)
                    )
                )
                .contentShape(shape)
                .clipShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

extension View {
    /// Convenience: a rounded plain button whose highlight stays within `radius`.
    func coachRoundedButton(radius: CGFloat, palette: BrutalistPalette) -> some View {
        buttonStyle(
            CoachRoundedButtonStyle(
                cornerRadius: radius,
                hoverFill: palette.fg.color.opacity(0.08),
                pressFill: palette.fg.color.opacity(0.14)
            ))
    }
}

/// Live NSVisualEffectView material so the panel self-corrects for legibility over
/// arbitrary call backgrounds (vibrancy + system label colors on top).
struct CoachMaterialBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
