import Foundation
import XCTest

@testable import SharedCore

/// Mode resolution hardening: compiled-regex caching, and invalid user
/// patterns skipping their mode LOUDLY (diagnostics + log) instead of
/// aborting resolution for every mode.
final class ModeDiagnosticsTests: XCTestCase {

    func testRegexCacheReturnsSameCompiledInstance() throws {
        let first = try ModeRegexCache.compiled("com\\.apple\\..*")
        let second = try ModeRegexCache.compiled("com\\.apple\\..*")
        XCTAssertTrue(first === second, "same pattern+options must hit the cache")

        let caseInsensitive = try ModeRegexCache.compiled("com\\.apple\\..*", options: [.caseInsensitive])
        XCTAssertFalse(first === caseInsensitive, "different options are distinct cache entries")
    }

    func testRegexCacheStillThrowsForInvalidPattern() {
        XCTAssertThrowsError(try ModeRegexCache.compiled("([unclosed"))
    }

    func testInvalidBundlePatternSkipsModeAndRecordsIssue() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let broken = Mode.makeCustom(
            name: "Broken",
            bundleIDRegex: "([unclosed",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        try await registry.add(broken)

        let diagnostics = ModeDiagnostics()
        let resolver = ModeResolver(
            registry: registry,
            bundleIDProvider: { "com.apple.mail" },
            diagnostics: diagnostics
        )

        // Resolution succeeds despite the broken mode (it used to throw and
        // kill dictation everywhere).
        let resolved = try await resolver.resolveCurrent()
        XCTAssertEqual(resolved.name, "Email")

        // …and the breakage is loud + queryable for Settings.
        let issues = diagnostics.currentIssues()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.modeName, "Broken")
        XCTAssertEqual(issues.first?.field, .bundleIDRegex)
        XCTAssertEqual(issues.first?.pattern, "([unclosed")
    }

    func testFixedPatternClearsRecordedIssue() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        var custom = Mode.makeCustom(
            name: "Mendable",
            bundleIDRegex: "([unclosed",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        try await registry.add(custom)

        let diagnostics = ModeDiagnostics()
        let resolver = ModeResolver(
            registry: registry,
            bundleIDProvider: { "com.apple.mail" },
            diagnostics: diagnostics
        )
        _ = try await resolver.resolveCurrent()
        XCTAssertEqual(diagnostics.currentIssues().count, 1)

        // User fixes the pattern.
        custom.bundleIDRegex = "com\\.apple\\.mail"
        custom.touch()
        try await registry.update(custom)
        let resolved = try await resolver.resolveCurrent()
        XCTAssertEqual(resolved.name, "Mendable")
        XCTAssertTrue(diagnostics.currentIssues().isEmpty, "fixing the pattern clears the issue")
    }

    func testRegistryBootstrapIsRetryableAfterFailure() async throws {
        // A registry pointed at a bundle with no mode resource fails its first
        // bootstrap — and must remain retryable rather than latching dead.
        let emptyBundleDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "empty-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyBundleDir) }
        let emptyBundle = Bundle(url: emptyBundleDir)

        let registry = ModeRegistry(persistence: .ephemeral, bundle: emptyBundle ?? Bundle.main)
        do {
            try await registry.bootstrap()
            // Bundle.main may incidentally contain the resource when tests run
            // inside the app bundle; only assert the retry path when the first
            // attempt genuinely failed.
            return
        } catch {
            // expected: resource missing
        }
        let all = await registry.all()
        XCTAssertTrue(all.isEmpty, "failed bootstrap must roll its partial state back")

        // Retry must run the load again (and fail the same way here — the
        // point is it didn't no-op behind the success latch).
        do {
            try await registry.bootstrap()
            XCTFail("expected the retry to attempt (and fail) the load again")
        } catch {
            // expected — it retried instead of silently returning
        }
    }
}
