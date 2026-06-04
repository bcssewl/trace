import XCTest

@testable import SharedCore

final class BridgesAccessibilityPasteTests: XCTestCase {
    func testAxPathWinsWithoutTouchingClipboard() async throws {
        let ax = StubAXInsert(result: true)
        let clipboard = StubClipboard(initial: "old")
        let paste = AccessibilityPaste(
            ax: ax, clipboard: clipboard, keys: StubKeySynthesizer(),
            restoreDelayNanos: 1_000_000
        )

        let result = try await paste.insert("hello")
        let current = await clipboard.value()

        XCTAssertEqual(result, .axInserted)
        XCTAssertEqual(current, "old")
    }

    func testFallbackRestoresClipboardAfterCommandV() async throws {
        let clipboard = StubClipboard(initial: "old")
        let keys = StubKeySynthesizer()
        let paste = AccessibilityPaste(
            ax: StubAXInsert(result: false),
            clipboard: clipboard,
            keys: keys,
            restoreDelayNanos: 1_000_000
        )

        let result = try await paste.insert("hello")
        let final = await clipboard.value()
        let sent = await keys.sentValues()

        XCTAssertEqual(result, .clipboardPaste)
        XCTAssertEqual(final, "old")
        XCTAssertEqual(sent, [.commandV])
    }
}

private struct StubAXInsert: AXTextInserting {
    let result: Bool
    func insertAtFocusedElement(_ text: String) async -> Bool { result }
}

private actor StubClipboard: ClipboardStoring {
    private var stored: String?
    init(initial: String?) { self.stored = initial }
    func readString() async -> String? { stored }
    func writeString(_ text: String) async { stored = text }
    func value() -> String? { stored }
}

private actor StubKeySynthesizer: KeySynthesizing {
    private var sent: [SynthesizedKey] = []
    func send(_ key: SynthesizedKey) async -> Bool {
        sent.append(key)
        return true
    }
    func sentValues() -> [SynthesizedKey] { sent }
}
