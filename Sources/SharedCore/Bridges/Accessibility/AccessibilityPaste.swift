import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum PasteResult: String, Sendable, Equatable, Hashable, Codable {
    case axInserted
    case clipboardPaste
    case copiedOnly
}

public protocol AXTextInserting: Sendable {
    func insertAtFocusedElement(_ text: String) async -> Bool
}
public protocol ClipboardStoring: Sendable {
    func readString() async -> String?
    func writeString(_ text: String) async
}
public enum SynthesizedKey: Sendable, Equatable { case commandV }
public protocol KeySynthesizing: Sendable {
    func send(_ key: SynthesizedKey) async -> Bool
}

public actor AccessibilityPaste {
    private let ax: any AXTextInserting
    private let clipboard: any ClipboardStoring
    private let keys: any KeySynthesizing
    private let restoreDelayNanos: UInt64

    public init(
        ax: any AXTextInserting = LiveAXTextInserter(),
        clipboard: any ClipboardStoring = PasteboardClipboard(),
        keys: any KeySynthesizing = CGEventKeySynthesizer(),
        restoreDelayNanos: UInt64 = 200_000_000
    ) {
        self.ax = ax
        self.clipboard = clipboard
        self.keys = keys
        self.restoreDelayNanos = restoreDelayNanos
    }

    public func insert(_ text: String) async throws -> PasteResult {
        if await ax.insertAtFocusedElement(text) {
            return .axInserted
        }

        let previous = await clipboard.readString()
        await clipboard.writeString(text)
        // The synthetic ⌘V only lands when Accessibility is granted — without it
        // macOS silently drops the keystroke, yet `keys.send` still returns true
        // for a posted-but-dropped event. Use the PROMPTING trust check: macOS
        // never auto-prompts for Accessibility (unlike mic/camera), so this is
        // what actually surfaces the "grant Accessibility" dialog when it's
        // missing. It returns current trust either way; on failure we leave the
        // text on the clipboard for a manual ⌘V.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary), await keys.send(.commandV) {
            try? await Task.sleep(nanoseconds: restoreDelayNanos)
            if let previous { await clipboard.writeString(previous) }
            return .clipboardPaste
        }

        return .copiedOnly
    }
}

public struct LiveAXTextInserter: AXTextInserting {
    public init() {}

    public func insertAtFocusedElement(_ text: String) async -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return false }
        let elt = element as! AXUIElement

        // Bail out if the focused element is inside OUR process. AX calls
        // against same-process elements are dispatched through the main
        // runloop, which is currently blocked awaiting `paste.insert(...)` to
        // return — that classic AX self-call would deadlock and produce a
        // beachball. Returning false here pushes the caller to the clipboard
        // + ⌘V fallback, which works fine in our own UI.
        var targetPID: pid_t = 0
        if AXUIElementGetPid(elt, &targetPID) == .success,
            targetPID == ProcessInfo.processInfo.processIdentifier
        {
            return false
        }

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
                return true
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
            if before != after { return true }
        }
        return false
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
}

public struct CGEventKeySynthesizer: KeySynthesizing {
    public init() {}
    public func send(_ key: SynthesizedKey) async -> Bool {
        guard key == .commandV else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return down != nil && up != nil
    }
}
