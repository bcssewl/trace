import XCTest

@testable import SharedCore

final class BridgesFrontmostAppMonitorTests: XCTestCase {
    func testEmitsOnlyWhenBundleIdentifierChanges() async {
        let source = StubFrontmostSource(apps: [
            .init(bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit", executableURL: nil),
            .init(bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit", executableURL: nil),
            .init(bundleIdentifier: "com.todesktop.230313mzl4w4u92", localizedName: "Cursor", executableURL: nil),
        ])
        let monitor = FrontmostAppMonitor(source: source)

        let apps = await monitor.collectOnePassForTesting()

        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.apple.TextEdit", "com.todesktop.230313mzl4w4u92"])
    }
}

private struct StubFrontmostSource: FrontmostAppSourcing {
    let apps: [FrontmostApp]
    func currentSequenceForTesting() async -> [FrontmostApp] { apps }
}
