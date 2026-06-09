import AppKit
import CoreGraphics
import Foundation

/// A short-lived CoreGraphics event tap that swallows a *plain* Return keypress
/// and reports it — the mechanism behind "press Return to finish dictation and
/// send".
///
/// It is alive only while dictation is recording. We need an **active** tap
/// (one that can consume the event), not a passive `NSEvent` monitor, because
/// the Return must NOT reach the focused app: otherwise the app would receive a
/// stray Return — sending an empty/half-typed message — before our transcript
/// has even landed. We swallow it instead, finish the dictation, insert the
/// text, and then synthesise our own Return to submit.
///
/// An active tap requires Accessibility trust (the same grant the paste path
/// already relies on). Without it `start()` reports `.missingPermission` and the
/// caller simply leaves Return alone rather than degrading silently.
@MainActor
public final class EnterKeyInterceptor {
    public enum StartResult: Equatable {
        case started
        case missingPermission
        case failed
    }

    /// Main Return (kVK_Return) and numeric-keypad Enter (kVK_ANSI_KeypadEnter).
    private nonisolated static let returnKeyCodes: Set<Int64> = [36, 76]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onReturn: @MainActor () -> Void
    /// Which bare keypresses this tap swallows (Return/Enter by default; the
    /// Escape variant uses kVK_Escape).
    private let interceptKeyCodes: Set<Int64>

    /// - Parameter onReturn: invoked (on the main actor, out-of-band from the
    ///   tap callback) when a plain Return is intercepted.
    public init(onReturn: @escaping @MainActor () -> Void) {
        self.onReturn = onReturn
        self.interceptKeyCodes = Self.returnKeyCodes
    }

    /// Same machinery, different key — used by `EscapeKeyInterceptor`.
    init(keyCodes: Set<Int64>, onIntercept: @escaping @MainActor () -> Void) {
        self.onReturn = onIntercept
        self.interceptKeyCodes = keyCodes
    }

    @discardableResult
    public func start() -> StartResult {
        guard tap == nil else { return .started }
        // An active (event-consuming) tap is only permitted for an
        // Accessibility-trusted process. Don't prompt here — the paste path owns
        // the prompt; we just decline cleanly if the grant isn't there yet.
        guard AXIsProcessTrusted() else { return .missingPermission }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<EnterKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                    return me.handle(type: type, event: event)
                },
                userInfo: refcon
            )
        else {
            return .failed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return .started
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // The tap source is attached to the main run loop, so this callback always
    // runs on the main thread — hence `assumeIsolated` is sound. It is marked
    // `nonisolated` only so the C function-pointer callback can reach it.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disarms a tap whose callback ever ran long, or across
            // some input transitions — re-arm it so Return keeps working.
            MainActor.assumeIsolated {
                if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return nil

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard interceptKeyCodes.contains(keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            // Only a *bare* Return submits. Let Shift/⌘/Ctrl/⌥ + Return through
            // untouched (e.g. Shift+Return for a newline) so we never hijack a
            // deliberate modifier combo.
            let modifiers: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
            guard event.flags.intersection(modifiers).isEmpty else {
                return Unmanaged.passUnretained(event)
            }
            let intercepted = MainActor.assumeIsolated { () -> Bool in
                // Don't hijack Return inside our OWN UI — if Trace is the active
                // app the user is typing into Trace (a search box, a field), not
                // dictating into someone else's app, so leave their Return be.
                if NSApplication.shared.isActive { return false }
                // Disarm immediately (safe from within the callback) so a second
                // Return in the same instant can't double-fire, then hand off on
                // the next main-loop turn — invalidating the port from inside its
                // own callback is not safe, so we never do the teardown here.
                if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: false) }
                let callback = self.onReturn
                DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
                return true
            }
            // Swallow the Return only when we acted on it — otherwise pass it on.
            return intercepted ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Esc-to-cancel for dictation: a short-lived active tap that swallows a
/// *bare* Escape keypress while a dictation is recording and reports it, so
/// the caller can cancel the capture (discard audio + spool) without the
/// Escape also reaching the focused app — where it could close a dialog or
/// exit a text field the user was dictating into.
///
/// Same mechanics, trust requirements, and bare-key-only semantics as
/// `EnterKeyInterceptor` (it shares the implementation); alive only while
/// dictation records. The tap disarms itself after one interception.
@MainActor
public final class EscapeKeyInterceptor {
    /// kVK_Escape.
    private static let escapeKeyCode: Int64 = 53

    private let inner: EnterKeyInterceptor

    /// - Parameter onEscape: invoked (on the main actor, out-of-band from the
    ///   tap callback) when a plain Escape is intercepted.
    public init(onEscape: @escaping @MainActor () -> Void) {
        self.inner = EnterKeyInterceptor(keyCodes: [Self.escapeKeyCode], onIntercept: onEscape)
    }

    @discardableResult
    public func start() -> EnterKeyInterceptor.StartResult {
        inner.start()
    }

    public func stop() {
        inner.stop()
    }
}
