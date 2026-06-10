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
        // The in-overlay "Minimise" button posts this; minimise-to-pill on receipt.
        NotificationCenter.default.addObserver(
            forName: .traceCoachOverlayHide, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.minimizeToPill() }
        }
        // The in-overlay "Dismiss" button (and ⌥esc) posts this; genuinely hide
        // for the rest of the meeting on receipt.
        NotificationCenter.default.addObserver(
            forName: .traceCoachOverlayDismiss, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissForMeeting() }
        }
        // Reopen hook (menu bar / coordinator) for a dismissed overlay.
        NotificationCenter.default.addObserver(
            forName: .traceCoachOverlayReopen, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reopen() }
        }
        installKeyMonitor()
    }

    // MARK: Mode observation (armed only while the panel is visible)

    /// Generation token: re-arming bumps it so a stale armed tracking from a
    /// previous show/hide cycle dies on its (single) late fire instead of
    /// resurrecting the loop.
    private var observationGeneration = 0
    /// Whether the observation loop should keep re-arming. False while the
    /// overlay is hidden/dismissed — there is nothing to re-frame off-screen, so
    /// the loop is torn down rather than ticking forever.
    private var observationActive = false

    private func startObservingModeIfNeeded() {
        guard !observationActive else { return }
        observationActive = true
        observationGeneration += 1
        armModeObservation(generation: observationGeneration)
    }

    private func stopObservingMode() {
        // An already-armed tracking may fire once more; the generation/active
        // guards in its onChange make it a no-op that does not re-arm.
        observationActive = false
    }

    /// React to `state.mode` / `state.pillHovered` changes — whether the
    /// controller flips them or the SwiftUI tree does (pill button, ask chip,
    /// header expand).
    ///
    /// On a pill↔card transition we re-frame the NSPanel so the
    /// content is never clipped into the wrong size. Re-arms after each fire,
    /// but ONLY while the overlay is visible (`observationActive`).
    private func armModeObservation(generation: Int) {
        withObservationTracking {
            _ = state.mode
            // Also track pill-hover: hovering the collapsed pill grows its frame so
            // the revealed Ask chips aren't clipped, then shrinks it back on exit.
            _ = state.pillHovered
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationActive,
                    generation == self.observationGeneration
                else { return }
                self.syncFrameToMode()
                self.armModeObservation(generation: generation)
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
    /// An explicit present (meeting start, manual trigger) always clears a
    /// dismissed-for-meeting state — the user asked for the coach back.
    ///
    /// The SwiftUI tree draws over a live
    /// NSVisualEffectView material so it stays legible over any call background.
    public func present(projectName: String = "Project") {
        state.projectName = projectName
        state.dismissState.reopen()
        // Size the panel for the current mode before showing it (the observation
        // path only fires on subsequent *changes*, not the initial present).
        syncFrameToMode(force: !hasRestoredFrame)
        hasRestoredFrame = true
        panel.orderFrontRegardless()
        startObservingModeIfNeeded()
    }

    public func update(activeCard: CoachCard?) {
        // While dismissed for the meeting, new cards must not repopulate the
        // hidden panel (they would pop up stale on the next present). Clearing
        // (nil) is always allowed.
        if activeCard != nil, !state.dismissState.acceptsCards { return }
        state.activeCard = activeCard
        // A real card surfaces the full cue card; an empty result must NOT pop
        // an empty card — stay compact.
        if let card = activeCard, !card.isEmpty {
            state.mode = .card
            state.surfacedAt = Date()
        } else {
            // No useful card → collapse to listening pill (don't show empty card).
            if state.mode == .card { state.mode = .compact }
        }
    }

    public func appendRecentTrigger(_ trigger: RecentTrigger) {
        state.recentTriggers.insert(trigger, at: 0)
        if state.recentTriggers.count > 8 {
            state.recentTriggers.removeLast()
        }
    }

    /// Apply a listener health event to the overlay: drives the status banner
    /// (model unavailable / recovered).
    ///
    /// The listener's emission is already edge-triggered (one event per
    /// outage), and the banner model additionally honours a user dismissal — so
    /// a dead model shows one banner, not one per check.
    public func applyHealthEvent(_ event: CoachHealthEvent) {
        state.health.apply(event)
    }

    /// Reset per-meeting overlay state (health banner, dismissed-for-meeting).
    /// Call at meeting start, alongside `CoachListener.beginMeeting()`.
    public func prepareForNewMeeting() {
        state.health.resetForNewMeeting()
        state.dismissState.reopen()
    }

    public func hide() {
        stopObservingMode()
        panel.orderOut(nil)
    }

    /// Minimise to the compact pill rather than fully hiding — the coach keeps
    /// listening; the user can click the pill to bring the card back.
    public func minimizeToPill() {
        state.mode = .compact
        state.activeCard = nil
    }

    /// Genuinely hide the overlay for the rest of the meeting (the "Dismiss"
    /// button / ⌥esc): the panel orders out and incoming cards no longer
    /// repopulate it.
    ///
    /// The coordinator observes the same notification and PAUSES the
    /// listener's automatic checks — each is a paid cloud call that would
    /// produce cards nobody sees. Reopen via `reopen()` (or any explicit
    /// `present`, e.g. the manual trigger) resumes them, and a new meeting
    /// always starts fresh.
    public func dismissForMeeting() {
        state.dismissState.dismissForMeeting()
        state.activeCard = nil
        state.mode = .compact
        state.surfacedAt = nil
        stopObservingMode()
        panel.orderOut(nil)
    }

    /// Bring back a dismissed/hidden overlay without touching the project name —
    /// the coordinator/menu-bar reopen hook (also reachable via the
    /// `.traceCoachOverlayReopen` notification).
    public func reopen() {
        state.dismissState.reopen()
        syncFrameToMode(force: !hasRestoredFrame)
        hasRestoredFrame = true
        panel.orderFrontRegardless()
        startObservingModeIfNeeded()
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
    /// ⌥esc DISMISSES for the rest of
    /// the meeting — matching the header button labelled "Dismiss (⌥esc)" — it
    /// does not merely minimise. A non-activating panel never holds key focus,
    /// so a local monitor catches it whenever Trace is frontmost; the global
    /// fallback (registered by the coordinator) handles it during a call when
    /// another app is frontmost.
    private func installKeyMonitor() {
        keyMonitorBox.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌥esc: option held + escape (keyCode 53). POST the dismiss like
            // every other dismiss path (button, global hotkey) — the
            // coordinator observes the same notification to PAUSE the
            // listener's paid checks. Calling dismissForMeeting() directly
            // here would hide the overlay while the meter kept running.
            if event.keyCode == 53, event.modifierFlags.contains(.option) {
                NotificationCenter.default.post(name: .traceCoachOverlayDismiss, object: nil)
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

// NOTE: `RecentTrigger` moved into CoachModule (Sources/CoachModule/RecentTrigger.swift)
// so its label hygiene — clamping empty/garbled LLM titles to an honest per-mode
// fallback — is enforced at the data layer for every caller.

/// Notifications the overlay's own SwiftUI tree posts (and the coordinator may
/// post) to drive the controller. Defined here, next to their handlers.
extension Notification.Name {
    /// Genuinely dismiss the overlay for the rest of the meeting (the header
    /// "Dismiss" button / ⌥esc). Distinct from `.traceCoachOverlayHide`, which
    /// minimises to the pill.
    public static let traceCoachOverlayDismiss = Notification.Name("app.trace.coachOverlayDismiss")
    /// Reopen a dismissed overlay (menu-bar / coordinator hook).
    public static let traceCoachOverlayReopen = Notification.Name("app.trace.coachOverlayReopen")
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
    public var recentTriggers: [RecentTrigger] = []
    /// Surface state: starts compact (listening pill) so a meeting never auto-pops
    /// a full panel; a real card flips it to `.card`.
    public var mode: CoachOverlayMode = .compact
    /// When the current passive card was surfaced — drives the auto-dismiss timer.
    public var surfacedAt: Date?
    /// True while the mouse hovers the collapsed pill — reveals the Ask chips and
    /// grows the pill frame to fit them (see `syncFrameToMode`).
    public var pillHovered: Bool = false
    /// Health banner state, driven by listener health events via
    /// `CoachOverlayController.applyHealthEvent`. The model (in CoachModule)
    /// owns the dismissal/rate-limit rules so they're testable without AppKit.
    public var health = CoachHealthBannerModel()
    /// Dismissed-for-meeting state (the "Dismiss" button / ⌥esc) — model-level
    /// so the semantics are testable without AppKit.
    public var dismissState = CoachOverlayDismissState()

    public init() {}
}

extension CoachCard {
    /// Whether the card has anything worth showing.
    ///
    /// An empty body must not pop a card.
    var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Auto-dismiss cards after the timeout (paused while hovered).
    private func tickAutoDismiss() {
        guard state.mode == .card, !hovering else { return }
        guard state.activeCard != nil, let surfacedAt = state.surfacedAt else { return }
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
                    if let banner = state.health.activeMessage {
                        // Health problem → the pill says so even while collapsed
                        // (amber warning replaces the listening dot; full text in
                        // the card's banner).
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(BrutalistPalette.semantic(scheme).warning.color)
                            .help(banner)
                    } else {
                        BrutalistPulsingDot(color: palette.primary.color, size: 7)
                    }
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
            if let banner = state.health.activeMessage {
                healthBanner(banner)
                Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            }
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
            iconButton(systemName: "minus", help: "Minimise to pill") {
                NotificationCenter.default.post(name: .traceCoachOverlayHide, object: nil)
            }
            iconButton(systemName: "xmark", help: "Dismiss for this meeting (⌥esc)") {
                NotificationCenter.default.post(name: .traceCoachOverlayDismiss, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Whole panel is drag-anywhere (isMovableByWindowBackground); the header's
        // own buttons still consume their clicks, so no explicit drag region needed.
    }

    /// Non-intrusive, dismissible health banner (model unavailable / RAG
    /// degraded). One per outage — the banner model + the orchestrator's
    /// edge-triggered events keep it from re-raising per utterance.
    private func healthBanner(_ message: String) -> some View {
        let semantic = BrutalistPalette.semantic(scheme)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(semantic.warning.color)
                .padding(.top, 1)
            Text(message)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fg.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.health.dismissCurrent()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.fgMuted.color)
                    .frame(width: 18, height: 18)
            }
            .coachRoundedButton(radius: 5, palette: palette)
            .help("Hide this notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(semantic.warning.color.opacity(scheme == .dark ? 0.14 : 0.10))
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
        let badge = Self.kindBadge(for: card)
        return VStack(alignment: .leading, spacing: 9) {
            // kind badge — one restrained per-kind dot, not everything orange —
            // plus the cue's surfacing time, so a card that's been sitting there
            // can't masquerade as fresh.
            HStack(spacing: 6) {
                Circle().fill(Self.kindColor(card.kind, scheme: scheme, palette: palette)).frame(width: 6, height: 6)
                Text(badge)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fgMuted.color)
                Spacer()
                Text(card.createdAt, style: .time)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .help("When this card surfaced")
            }
            // context (what this card is about)
            if !card.title.isEmpty {
                Text(card.title)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // the card body, accented with a left-rule; clamps with Show more
            bodyView(card)
            // grounding quote — the verbatim line from the user's notes this
            // card stands on, shown so trust is inspectable at a glance.
            if card.isGrounded {
                groundingView(card)
            }
            sourceRow(card)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The accented card body with a left-rule.
    ///
    /// Long bodies clamp to a few
    /// lines and reveal a Show more / Show less toggle.
    @ViewBuilder
    private func bodyView(_ card: CoachCard) -> some View {
        let text = card.body
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

    /// The verbatim quote from the user's notes a grounded card stands on.
    private func groundingView(_ card: CoachCard) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 9))
                .foregroundStyle(palette.fgMuted.color)
                .padding(.top, 2)
            Text("“\(card.grounding)”")
                .font(BrutalistTypography.caption)
                .italic()
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private func sourceRow(_ card: CoachCard) -> some View {
        let grounded = card.isGrounded
        return HStack(spacing: 5) {
            Image(systemName: grounded ? "doc.text.magnifyingglass" : "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(grounded ? palette.fgMuted.color : palette.fgSidebar.color.opacity(0.7))
            Text(grounded ? "From your notes" : "AI · general knowledge")
                .font(BrutalistTypography.caption)
                .foregroundStyle(grounded ? palette.fgMuted.color : palette.fgSidebar.color.opacity(0.7))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.top, 1)
        // Ungrounded general knowledge reads visibly lower-key than a grounded
        // notes source (trust gradient).
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
            recentLog
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var recentLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent cues")
                    .font(BrutalistTypography.groupTitle)
                    .foregroundStyle(palette.fgMuted.color)
                Spacer()
                // Withholding is never silent: cards held back by the budget or
                // the spacing gate land here greyed out, so the count is honest.
                let surfaced = state.recentTriggers.filter(\.wasSurfaced).count
                let withheld = state.recentTriggers.count - surfaced
                Text(withheld > 0 ? "\(surfaced) shown · \(withheld) held back" : "\(surfaced) shown")
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
                    if !trigger.wasSurfaced {
                        Text("held back")
                            .font(BrutalistTypography.caption)
                            .foregroundStyle(palette.fgMuted.color)
                    }
                    Spacer()
                    Text(trigger.timestamp, style: .time)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                    Text(Self.kindLabel(trigger.kind))
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Trust + kind treatment

    private static func kindBadge(for card: CoachCard) -> String {
        switch card.kind {
        case .answer: return card.isGrounded ? "Answer · from your notes" : "Answer"
        case .recall: return "From your notes"
        case .suggestion: return "Try saying"
        }
    }

    static func kindLabel(_ kind: CoachCardKind) -> String {
        switch kind {
        case .answer: return "Answer"
        case .recall: return "Recall"
        case .suggestion: return "Suggestion"
        }
    }

    /// One restrained per-kind accent dot (not everything orange).
    ///
    /// Pulls from the
    /// shared semantic palette so green/blue/amber read correctly in both schemes.
    private static func kindColor(_ kind: CoachCardKind, scheme: ColorScheme, palette: BrutalistPalette) -> Color {
        let semantic = BrutalistPalette.semantic(scheme)
        switch kind {
        case .recall: return semantic.success.color  // green = from your notes
        case .answer: return semantic.info.color  // blue = answer
        case .suggestion: return semantic.warning.color  // amber = a nudge
        }
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
