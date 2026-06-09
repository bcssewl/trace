import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum PasteResult: String, Sendable, Equatable, Hashable, Codable {
    case axInserted
    case clipboardPaste
    case copiedOnly
    /// The focused element is a secure (password) field. The text was NOT
    /// inserted and was NOT placed on the clipboard — dictated text must never
    /// leak into the pasteboard from a password context.
    case secureFieldRefused

    /// True when the text actually landed in the target app (as opposed to
    /// merely sitting on the clipboard, or being refused outright).
    public var didInsert: Bool {
        switch self {
        case .axInserted, .clipboardPaste: return true
        case .copiedOnly, .secureFieldRefused: return false
        }
    }
}

/// What the Accessibility inserter found at the focused element.
public enum AXInsertOutcome: Sendable, Equatable {
    /// Text verified in place via the AX API.
    case inserted
    /// Focused element is a secure/password field — caller must refuse.
    case secureField
    /// Focused element lives under an `AXWebArea` (browser/Electron). AX
    /// insertion is unreliable there; caller falls back to clipboard ⌘V and
    /// should treat the target as SLOW (Electron apps read the pasteboard
    /// asynchronously).
    case webArea
    /// No focused element / unverifiable insert / AX unavailable.
    case unavailable
}

/// Whether the focused element's value visibly contains a given string.
public enum AXVerifyResult: Sendable, Equatable {
    case confirmed
    case absent
    /// The element's value can't be read truthfully (web areas lie, AX read
    /// failed, …) — the caller must not draw conclusions either way.
    case unverifiable
}

public protocol AXTextInserting: Sendable {
    func attemptInsert(_ text: String) async -> AXInsertOutcome
    /// Reads the focused element's value and reports whether `text` is present.
    func verifyInsertedText(_ text: String) async -> AXVerifyResult
}

public protocol ClipboardStoring: Sendable {
    func readString() async -> String?
    func writeString(_ text: String) async
    /// Monotonic pasteboard change counter (`NSPasteboard.changeCount`
    /// semantics): increments every time ANY process takes ownership. Used to
    /// detect that someone wrote the pasteboard after us, so we never clobber
    /// newer content with our "restore".
    func changeCount() async -> Int
}

public enum SynthesizedKey: Sendable, Equatable {
    case commandV
    /// A bare Return/Enter keypress, used to submit after a dictation insert
    /// (the "press Return to send" ergonomic).
    case returnKey
}
public protocol KeySynthesizing: Sendable {
    func send(_ key: SynthesizedKey) async -> Bool
}

public actor AccessibilityPaste {
    private let ax: any AXTextInserting
    private let clipboard: any ClipboardStoring
    private let keys: any KeySynthesizing
    /// How long the pasted text is left on the clipboard before restoring the
    /// user's previous content — long enough for the target app to consume the
    /// ⌘V we synthesised.
    private let restoreDelayNanos: UInt64
    /// The same window for known-slow targets (web/Electron apps read the
    /// pasteboard asynchronously, sometimes hundreds of ms after the
    /// keystroke). Restoring too early there yields a blank paste AND a
    /// clobbered clipboard.
    private let slowRestoreDelayNanos: UInt64
    /// Accessibility-trust check, seamed for tests. The PROMPTING variant is
    /// used live: macOS never auto-prompts for Accessibility, so this is what
    /// surfaces the grant dialog when it's missing.
    private let trustCheck: @Sendable () -> Bool
    /// Pause before a synthesised Return on a normal target.
    private let returnDelayNanos: UInt64
    /// Pause before a synthesised Return on a slow (web/Electron) target.
    private let slowReturnDelayNanos: UInt64

    /// Context captured by the most recent `insert(_:)`, consumed by
    /// `submitReturn()` so the Return is timed/verified against the right
    /// target profile.
    private struct LastInsert {
        let text: String
        let result: PasteResult
        let slowTarget: Bool
    }
    private var lastInsert: LastInsert?

    public init(
        ax: any AXTextInserting = LiveAXTextInserter(),
        clipboard: any ClipboardStoring = PasteboardClipboard(),
        keys: any KeySynthesizing = CGEventKeySynthesizer(),
        restoreDelayNanos: UInt64 = 200_000_000,
        slowRestoreDelayNanos: UInt64 = 600_000_000,
        returnDelayNanos: UInt64 = 70_000_000,
        slowReturnDelayNanos: UInt64 = 300_000_000,
        trustCheck: @escaping @Sendable () -> Bool = AccessibilityPaste.promptingTrustCheck
    ) {
        self.ax = ax
        self.clipboard = clipboard
        self.keys = keys
        self.restoreDelayNanos = restoreDelayNanos
        self.slowRestoreDelayNanos = slowRestoreDelayNanos
        self.returnDelayNanos = returnDelayNanos
        self.slowReturnDelayNanos = slowReturnDelayNanos
        self.trustCheck = trustCheck
    }

    /// The synthetic ⌘V only lands when Accessibility is granted — without it
    /// macOS silently drops the keystroke, yet `keys.send` still returns true
    /// for a posted-but-dropped event. Use the PROMPTING trust check: macOS
    /// never auto-prompts for Accessibility (unlike mic/camera), so this is
    /// what actually surfaces the "grant Accessibility" dialog when it's
    /// missing.
    public static let promptingTrustCheck: @Sendable () -> Bool = {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    public func insert(_ text: String) async throws -> PasteResult {
        let outcome = await ax.attemptInsert(text)
        switch outcome {
        case .inserted:
            lastInsert = LastInsert(text: text, result: .axInserted, slowTarget: false)
            return .axInserted

        case .secureField:
            // Refuse loudly. No insert, no clipboard write — dictated text in a
            // password context must not end up anywhere it can leak.
            lastInsert = LastInsert(text: text, result: .secureFieldRefused, slowTarget: false)
            return .secureFieldRefused

        case .webArea, .unavailable:
            let slow = outcome == .webArea
            let result = await clipboardPaste(text, slowTarget: slow)
            lastInsert = LastInsert(text: text, result: result, slowTarget: slow)
            return result
        }
    }

    /// Clipboard ⌘V fallback with a safe restore policy:
    ///
    /// 1. Remember the user's clipboard, write ours, note `changeCount`.
    /// 2. Synthesise ⌘V; wait an adaptive window (longer for web/Electron).
    /// 3. Restore the user's clipboard ONLY if `changeCount` still matches our
    ///    write — if anything else wrote the pasteboard meanwhile, their newer
    ///    content wins and we never destroy it.
    private func clipboardPaste(_ text: String, slowTarget: Bool) async -> PasteResult {
        let previous = await clipboard.readString()
        await clipboard.writeString(text)
        let ourChangeCount = await clipboard.changeCount()

        guard trustCheck(), await keys.send(.commandV) else {
            // No trust / synthesis failed: leave the text on the clipboard for
            // a manual ⌘V.
            return .copiedOnly
        }

        try? await Task.sleep(nanoseconds: slowTarget ? slowRestoreDelayNanos : restoreDelayNanos)

        if let previous {
            let currentCount = await clipboard.changeCount()
            if currentCount == ourChangeCount {
                await clipboard.writeString(previous)
            }
            // else: the user (or an app) wrote the pasteboard after us — their
            // content is newer than both ours and the saved `previous`; leave
            // it untouched.
        }
        return .clipboardPaste
    }

    /// Fires the "Return to send" submit for the most recent insert — timed
    /// and, where possible, verified against the target:
    ///
    /// - AX-inserted into a truthful target: re-read the focused element and
    ///   only send Return once the text is confirmed present (one retry).
    /// - Clipboard paste into a web/Electron target: the AX value lies there,
    ///   so verification is impossible — use the longer settle delay instead.
    /// - Refused/copied-only outcomes: never submit (there is nothing in the
    ///   field to send).
    ///
    /// Returns `true` iff the Return was actually synthesised.
    public func submitReturn() async -> Bool {
        guard let last = lastInsert, last.result.didInsert else { return false }
        // One submit per insert — a duplicate call must not double-send.
        lastInsert = nil

        if last.result == .axInserted {
            switch await ax.verifyInsertedText(last.text) {
            case .confirmed:
                return await keys.send(.returnKey)
            case .absent:
                // The app may still be ingesting — give it one more beat.
                try? await Task.sleep(nanoseconds: returnDelayNanos * 2)
                if await ax.verifyInsertedText(last.text) == .absent {
                    Loggers.dictation.error(
                        "Return-to-send: inserted text not present in focused element — refusing to submit"
                    )
                    return false
                }
                return await keys.send(.returnKey)
            case .unverifiable:
                try? await Task.sleep(nanoseconds: returnDelayNanos)
                return await keys.send(.returnKey)
            }
        }

        // Clipboard paste: no truthful AX read available — scale the delay for
        // slow targets so the app has ingested the paste before Return lands.
        try? await Task.sleep(nanoseconds: last.slowTarget ? slowReturnDelayNanos : returnDelayNanos)
        return await keys.send(.returnKey)
    }
}

public struct LiveAXTextInserter: AXTextInserting {
    public init() {}

    public func attemptInsert(_ text: String) async -> AXInsertOutcome {
        guard let elt = Self.focusedElement() else { return .unavailable }

        // Bail out if the focused element is inside OUR process. AX calls
        // against same-process elements are dispatched through the main
        // runloop, which is currently blocked awaiting `paste.insert(...)` to
        // return — that classic AX self-call would deadlock and produce a
        // beachball. Returning unavailable pushes the caller to the clipboard
        // + ⌘V fallback, which works fine in our own UI.
        var targetPID: pid_t = 0
        if AXUIElementGetPid(elt, &targetPID) == .success,
            targetPID == ProcessInfo.processInfo.processIdentifier
        {
            return .unavailable
        }

        // Secure (password) fields FIRST: dictating into one must refuse
        // outright — not insert, and crucially not fall back to the clipboard,
        // which would leak the dictated secret into the pasteboard.
        if isSecureField(elt) { return .secureField }

        // Web & Electron text boxes (Chrome, Safari, Slack, VS Code, …) live
        // under an AXWebArea and DON'T honour the AX text contract: reads return
        // the field's placeholder instead of its value, the cursor reads as
        // position 0, and `setValue` reports success without a verifiable
        // result. Our read-modify-write insert below then mis-verifies and ends
        // up applying more than one strategy — typing the text TWICE and
        // splicing in the placeholder (the dictation-duplication bug). Decline
        // AX for these so the caller falls back to a single clipboard ⌘V, which
        // the app pastes natively: once, at the real cursor.
        if isInsideWebArea(elt) { return .webArea }

        // Read the current value + cursor range. If we have both, we can
        // perform a verifiable insert by computing the new value, writing it,
        // and confirming it stuck. This is more reliable than blindly setting
        // `kAXSelectedTextAttribute`, which returns .success on a wide range
        // of apps without actually inserting.
        if let currentValue = readString(elt, kAXValueAttribute),
            let currentRange = readRange(elt, kAXSelectedTextRangeAttribute)
        {
            let ns = currentValue as NSString
            let clampedLocation = max(0, min(currentRange.location, ns.length))
            let clampedLength = max(0, min(currentRange.length, ns.length - clampedLocation))
            let replaceRange = NSRange(location: clampedLocation, length: clampedLength)
            let newValue = ns.replacingCharacters(in: replaceRange, with: text)
            let setOK =
                AXUIElementSetAttributeValue(elt, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success
            if setOK, readString(elt, kAXValueAttribute) == newValue {
                // Move the cursor to the end of the inserted text.
                let newPos = clampedLocation + (text as NSString).length
                var range = CFRange(location: newPos, length: 0)
                if let rv = AXValueCreate(.cfRange, &range) {
                    _ = AXUIElementSetAttributeValue(elt, kAXSelectedTextRangeAttribute as CFString, rv)
                }
                return .inserted
            }
        }

        // Fallback path used by older AX-conformant text views: setting
        // kAXSelectedTextAttribute replaces the current selection with `text`.
        // Verify the value actually changed (some apps return .success without
        // mutating, which is exactly the bug we're working around).
        let before = readString(elt, kAXValueAttribute)
        let res = AXUIElementSetAttributeValue(elt, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if res == .success {
            let after = readString(elt, kAXValueAttribute)
            if before != after { return .inserted }
        }
        return .unavailable
    }

    public func verifyInsertedText(_ text: String) async -> AXVerifyResult {
        guard let elt = Self.focusedElement() else { return .unverifiable }
        // Web areas report placeholders instead of values — a read there is a
        // lie, not a verification.
        if isInsideWebArea(elt) { return .unverifiable }
        guard let value = readString(elt, kAXValueAttribute) else { return .unverifiable }
        return value.contains(text) ? .confirmed : .absent
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return nil }
        return (element as! AXUIElement)
    }

    /// True when the focused element is a secure text field (password entry).
    ///
    /// Checked via the AX subrole — `NSSecureTextField` and the WebKit/AppKit
    /// password inputs all report `AXSecureTextField`.
    private func isSecureField(_ elt: AXUIElement) -> Bool {
        readString(elt, kAXSubroleAttribute) == "AXSecureTextField"
    }

    private func readString(_ elt: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elt, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func readRange(_ elt: AXUIElement, _ attr: String) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elt, attr as CFString, &ref) == .success,
            let value = ref
        else { return nil }
        var cf = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &cf) else { return nil }
        return NSRange(location: cf.location, length: cf.length)
    }

    /// Walks up the accessibility hierarchy from `elt` looking for an
    /// `AXWebArea` — the container Chromium (Chrome, Arc, Brave, Edge, every
    /// Electron app) and WebKit (Safari) wrap web content in. Used to route web
    /// text boxes away from the AX read-modify-write insert, which corrupts and
    /// double-types in them (see call site). Bounded depth so a malformed or
    /// cyclic tree can't spin.
    private func isInsideWebArea(_ elt: AXUIElement) -> Bool {
        var current: AXUIElement? = elt
        var depth = 0
        while let node = current, depth < 16 {
            if readString(node, kAXRoleAttribute) == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                let p = parent
            else { break }
            current = (p as! AXUIElement)
            depth += 1
        }
        return false
    }
}

public actor PasteboardClipboard: ClipboardStoring {
    public init() {}
    public func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
    public func writeString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    public func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }
}

public struct CGEventKeySynthesizer: KeySynthesizing {
    public init() {}
    public func send(_ key: SynthesizedKey) async -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let virtualKey: CGKeyCode
        let flags: CGEventFlags
        switch key {
        case .commandV:
            virtualKey = 0x09  // V
            flags = .maskCommand
        case .returnKey:
            virtualKey = 0x24  // Return
            flags = []
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return down != nil && up != nil
    }
}
