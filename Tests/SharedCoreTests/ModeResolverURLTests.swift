import XCTest

@testable import SharedCore

/// BAS-5 — per-website dictation modes.
///
/// When the frontmost app is a browser, the
/// active tab's URL can select a more specific mode than the browser's bundle ID
/// (which is identical for every site). URL matches outrank bundle-ID matches;
/// non-browsers behave exactly as before.
private struct FakeBrowserTabReader: BrowserTabReading {
    let url: String?
    func activeBrowserTab(frontmostBundleID: String) async -> BrowserTabSignal? {
        url.map { BrowserTabSignal(browserBundleID: frontmostBundleID, url: $0) }
    }
}

final class ModeResolverURLTests: XCTestCase {
    private func registry(_ modes: [Mode]) async -> ModeRegistry {
        let r = ModeRegistry(persistence: .ephemeral)
        for mode in modes { await r.testInsert(mode) }
        return r
    }

    private func custom(_ name: String, bundle: String, url: String? = nil, at: TimeInterval) -> Mode {
        Mode.makeCustom(
            name: name, bundleIDRegex: bundle, urlRegex: url, systemPrompt: "",
            insertBehavior: .pasteAtCursor, afterInsertBehavior: .closeHud, now: at
        )
    }

    func testURLModeWinsOverBundleMatchInBrowser() async throws {
        // `Chrome` is the newer bundle match, so without URL matching it would win.
        let chrome = custom("Chrome", bundle: "com\\.google\\.Chrome", at: 100)
        let gmail = custom("Email", bundle: "com\\.google\\.Chrome", url: "mail\\.google\\.com", at: 50)
        let resolver = ModeResolver(
            registry: await registry([chrome, gmail]),
            bundleIDProvider: { "com.google.Chrome" },
            browserTabReader: FakeBrowserTabReader(url: "https://mail.google.com/mail/u/0/#inbox")
        )
        let mode = try await resolver.resolveCurrent()
        XCTAssertEqual(mode.name, "Email")
    }

    func testFallsBackToBundleWhenURLDoesNotMatch() async throws {
        let chrome = custom("Chrome", bundle: "com\\.google\\.Chrome", at: 100)
        let gmail = custom("Email", bundle: "com\\.google\\.Chrome", url: "mail\\.google\\.com", at: 50)
        let resolver = ModeResolver(
            registry: await registry([chrome, gmail]),
            bundleIDProvider: { "com.google.Chrome" },
            browserTabReader: FakeBrowserTabReader(url: "https://example.com/page")
        )
        let mode = try await resolver.resolveCurrent()
        XCTAssertEqual(mode.name, "Chrome")
    }

    func testNonBrowserIgnoresURLModes() async throws {
        // The URL would match `Email`, but a non-browser frontmost app must not
        // consult the tab URL — the newer catch-all wins instead.
        let base = custom("Default", bundle: ".*", at: 100)
        let gmail = custom("Email", bundle: ".*", url: "mail\\.google\\.com", at: 50)
        let resolver = ModeResolver(
            registry: await registry([base, gmail]),
            bundleIDProvider: { "com.acme.NotABrowser" },
            browserTabReader: FakeBrowserTabReader(url: "https://mail.google.com")
        )
        let mode = try await resolver.resolveCurrent()
        XCTAssertEqual(mode.name, "Default")
    }

    func testNoReaderBehavesAsBundleOnly() async throws {
        let chrome = custom("Chrome", bundle: "com\\.google\\.Chrome", at: 100)
        let gmail = custom("Email", bundle: "com\\.google\\.Chrome", url: "mail\\.google\\.com", at: 50)
        let resolver = ModeResolver(
            registry: await registry([chrome, gmail]),
            bundleIDProvider: { "com.google.Chrome" }
        )
        let mode = try await resolver.resolveCurrent()
        XCTAssertEqual(mode.name, "Chrome")
    }

    func testCompiledURLRegexNilWhenAbsent() throws {
        XCTAssertNil(try custom("A", bundle: ".*", at: 0).compiledURLRegex())
        XCTAssertNotNil(try custom("B", bundle: ".*", url: "mail\\.google\\.com", at: 0).compiledURLRegex())
    }
}
