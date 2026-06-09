import XCTest

@testable import SharedCore

final class BridgesAccessibilityPasteTests: XCTestCase {

    private func makePaste(
        ax: StubAXInsert,
        clipboard: StubClipboard,
        keys: StubKeySynthesizer = StubKeySynthesizer(),
        trusted: Bool = true
    ) -> AccessibilityPaste {
        AccessibilityPaste(
            ax: ax,
            clipboard: clipboard,
            keys: keys,
            restoreDelayNanos: 1_000_000,
            slowRestoreDelayNanos: 2_000_000,
            returnDelayNanos: 1_000_000,
            slowReturnDelayNanos: 2_000_000,
            trustCheck: { trusted }
        )
    }

    func testAxPathWinsWithoutTouchingClipboard() async throws {
        let ax = StubAXInsert(outcome: .inserted)
        let clipboard = StubClipboard(initial: "old")
        let paste = makePaste(ax: ax, clipboard: clipboard)

        let result = try await paste.insert("hello")
        let current = await clipboard.value()

        XCTAssertEqual(result, .axInserted)
        XCTAssertTrue(result.didInsert)
        XCTAssertEqual(current, "old")
    }

    func testFallbackRestoresClipboardAfterCommandV() async throws {
        let clipboard = StubClipboard(initial: "old")
        let keys = StubKeySynthesizer()
        let paste = makePaste(ax: StubAXInsert(outcome: .unavailable), clipboard: clipboard, keys: keys)

        let result = try await paste.insert("hello")
        let final = await clipboard.value()
        let sent = await keys.sentValues()

        XCTAssertEqual(result, .clipboardPaste)
        XCTAssertEqual(final, "old")
        XCTAssertEqual(sent, [.commandV])
    }

    /// Core changeCount policy: if anything else wrote the pasteboard between
    /// our write and the restore window, the user's NEWER content must win —
    /// we never write over it.
    func testNoRestoreWhenPasteboardChangedUnderUs() async throws {
        let clipboard = StubClipboard(initial: "old")
        // After our write, simulate another process taking the pasteboard.
        await clipboard.scheduleExternalWrite("newer-from-user")
        let paste = makePaste(ax: StubAXInsert(outcome: .unavailable), clipboard: clipboard)

        let result = try await paste.insert("hello")
        let final = await clipboard.value()

        XCTAssertEqual(result, .clipboardPaste)
        XCTAssertEqual(final, "newer-from-user")
    }

    /// Empty prior clipboard: nothing to restore; our text stays available.
    func testNoPreviousClipboardLeavesTextInPlace() async throws {
        let clipboard = StubClipboard(initial: nil)
        let paste = makePaste(ax: StubAXInsert(outcome: .unavailable), clipboard: clipboard)

        let result = try await paste.insert("hello")
        let final = await clipboard.value()

        XCTAssertEqual(result, .clipboardPaste)
        XCTAssertEqual(final, "hello")
    }

    func testUntrustedProcessLeavesTextOnClipboardAsCopyOnly() async throws {
        let clipboard = StubClipboard(initial: "old")
        let keys = StubKeySynthesizer()
        let paste = makePaste(
            ax: StubAXInsert(outcome: .unavailable), clipboard: clipboard, keys: keys, trusted: false)

        let result = try await paste.insert("hello")
        let final = await clipboard.value()
        let sent = await keys.sentValues()

        XCTAssertEqual(result, .copiedOnly)
        XCTAssertFalse(result.didInsert)
        XCTAssertEqual(final, "hello")  // left for a manual ⌘V
        XCTAssertTrue(sent.isEmpty)
    }

    /// Secure (password) fields refuse outright: no insert, and crucially the
    /// dictated text must NOT be written to the clipboard.
    func testSecureFieldRefusesWithoutTouchingClipboard() async throws {
        let clipboard = StubClipboard(initial: "old")
        let keys = StubKeySynthesizer()
        let paste = makePaste(ax: StubAXInsert(outcome: .secureField), clipboard: clipboard, keys: keys)

        let result = try await paste.insert("hunter2 secret")
        let final = await clipboard.value()
        let writes = await clipboard.writeLog()
        let sent = await keys.sentValues()

        XCTAssertEqual(result, .secureFieldRefused)
        XCTAssertFalse(result.didInsert)
        XCTAssertEqual(final, "old")
        XCTAssertTrue(writes.isEmpty, "secure-field refusal must never write the pasteboard")
        XCTAssertTrue(sent.isEmpty)
    }

    /// Web/Electron targets use the clipboard path and still restore safely.
    func testWebAreaFallsBackToClipboardAndRestores() async throws {
        let clipboard = StubClipboard(initial: "old")
        let paste = makePaste(ax: StubAXInsert(outcome: .webArea), clipboard: clipboard)

        let result = try await paste.insert("hello web")
        let final = await clipboard.value()

        XCTAssertEqual(result, .clipboardPaste)
        XCTAssertEqual(final, "old")
    }

    // MARK: submitReturn

    func testSubmitReturnAfterVerifiedAXInsert() async throws {
        let ax = StubAXInsert(outcome: .inserted, verify: .confirmed)
        let keys = StubKeySynthesizer()
        let paste = makePaste(ax: ax, clipboard: StubClipboard(initial: nil), keys: keys)

        _ = try await paste.insert("hello")
        let submitted = await paste.submitReturn()
        let sent = await keys.sentValues()

        XCTAssertTrue(submitted)
        XCTAssertEqual(sent, [.returnKey])
    }

    func testSubmitReturnRefusesWhenInsertedTextAbsent() async throws {
        let ax = StubAXInsert(outcome: .inserted, verify: .absent)
        let keys = StubKeySynthesizer()
        let paste = makePaste(ax: ax, clipboard: StubClipboard(initial: nil), keys: keys)

        _ = try await paste.insert("hello")
        let submitted = await paste.submitReturn()
        let sent = await keys.sentValues()

        XCTAssertFalse(submitted)
        XCTAssertTrue(sent.isEmpty, "Return must not fire when the text never landed")
        let verifications = await ax.verifyCallCount()
        XCTAssertEqual(verifications, 2, "absent result gets exactly one retry")
    }

    func testSubmitReturnSendsWhenUnverifiable() async throws {
        let ax = StubAXInsert(outcome: .inserted, verify: .unverifiable)
        let keys = StubKeySynthesizer()
        let paste = makePaste(ax: ax, clipboard: StubClipboard(initial: nil), keys: keys)

        _ = try await paste.insert("hello")
        let submitted = await paste.submitReturn()
        let sent = await keys.sentValues()

        XCTAssertTrue(submitted)
        XCTAssertEqual(sent, [.returnKey])
    }

    func testSubmitReturnAfterClipboardPasteSends() async throws {
        let keys = StubKeySynthesizer()
        let paste = makePaste(
            ax: StubAXInsert(outcome: .webArea), clipboard: StubClipboard(initial: nil), keys: keys)

        _ = try await paste.insert("hello")
        let submitted = await paste.submitReturn()
        let sent = await keys.sentValues()

        XCTAssertTrue(submitted)
        XCTAssertEqual(sent, [.commandV, .returnKey])
    }

    func testSubmitReturnRefusesAfterSecureFieldAndCopyOnly() async throws {
        let keys = StubKeySynthesizer()
        let paste = makePaste(
            ax: StubAXInsert(outcome: .secureField), clipboard: StubClipboard(initial: nil), keys: keys)

        _ = try await paste.insert("hello")
        let submitted = await paste.submitReturn()

        XCTAssertFalse(submitted)
        let sent = await keys.sentValues()
        XCTAssertTrue(sent.isEmpty)
    }

    func testSubmitReturnWithoutAnyInsertIsFalse() async {
        let paste = makePaste(ax: StubAXInsert(outcome: .inserted), clipboard: StubClipboard(initial: nil))
        let submitted = await paste.submitReturn()
        XCTAssertFalse(submitted)
    }
}

// MARK: - doubles

private actor StubAXInsert: AXTextInserting {
    private let outcome: AXInsertOutcome
    private let verify: AXVerifyResult
    private var verifyCalls = 0

    init(outcome: AXInsertOutcome, verify: AXVerifyResult = .unverifiable) {
        self.outcome = outcome
        self.verify = verify
    }

    func attemptInsert(_ text: String) async -> AXInsertOutcome { outcome }
    func verifyInsertedText(_ text: String) async -> AXVerifyResult {
        verifyCalls += 1
        return verify
    }
    func verifyCallCount() -> Int { verifyCalls }
}

private actor StubClipboard: ClipboardStoring {
    private var stored: String?
    private var count: Int = 1
    /// When set, simulates another process writing the pasteboard BETWEEN the
    /// paste actor's two changeCount() observations (i.e. during the restore
    /// window): the first observation after our write returns unchanged, the
    /// second applies the external write first.
    private var pendingExternalWrite: String?
    private var observationsToSkip = 0
    private var writes: [String] = []

    init(initial: String?) { self.stored = initial }

    func readString() async -> String? { stored }

    func writeString(_ text: String) async {
        stored = text
        count += 1
        writes.append(text)
    }

    func changeCount() async -> Int {
        if pendingExternalWrite != nil, !writes.isEmpty {
            if observationsToSkip > 0 {
                observationsToSkip -= 1
            } else if let external = pendingExternalWrite {
                pendingExternalWrite = nil
                stored = external
                count += 1
            }
        }
        return count
    }

    func scheduleExternalWrite(_ text: String) {
        pendingExternalWrite = text
        observationsToSkip = 1
    }

    func value() -> String? { stored }
    func writeLog() -> [String] { writes }
}

private actor StubKeySynthesizer: KeySynthesizing {
    private var sent: [SynthesizedKey] = []
    func send(_ key: SynthesizedKey) async -> Bool {
        sent.append(key)
        return true
    }
    func sentValues() -> [SynthesizedKey] { sent }
}
