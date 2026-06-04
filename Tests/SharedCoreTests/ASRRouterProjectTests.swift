import XCTest

@testable import SharedCore

final class ASRRouterProjectTests: XCTestCase {

    func testBulkSetProjectOverridesApplied() async {
        let router = ASRRouter()
        let pid = UUID()
        let route = ASRRoute(engineIdentifier: "whisperkit", modelIdentifier: "large-v3", allowsCloud: false)
        await router.setProjectOverrides([.fileBatchEnglish: route], projectID: pid)

        let routed = await router.route(for: .fileBatchEnglish, projectID: pid)
        XCTAssertEqual(routed, route)
        // A task without a per-project override falls back to the default route.
        let other = await router.route(for: .voiceMemo, projectID: pid)
        XCTAssertEqual(other, ASRRouter.defaultRoutes[.voiceMemo])
    }

    func testClearProjectOverrides() async {
        let router = ASRRouter()
        let pid = UUID()
        await router.setProjectOverrides(
            [.fileBatchEnglish: ASRRoute(engineIdentifier: "x", modelIdentifier: "y", allowsCloud: false)],
            projectID: pid
        )
        await router.clearProjectOverrides(projectID: pid)
        let routed = await router.route(for: .fileBatchEnglish, projectID: pid)
        XCTAssertEqual(routed, ASRRouter.defaultRoutes[.fileBatchEnglish])
    }

    func testSensitiveLocalOnlyGuardStillAppliesToBulkOverride() async {
        // A cloud-allowing override for the local-only task must be ignored.
        let router = ASRRouter()
        let pid = UUID()
        await router.setProjectOverrides(
            [.sensitiveLocalOnly: ASRRoute(engineIdentifier: "cloud", modelIdentifier: "x", allowsCloud: true)],
            projectID: pid
        )
        let routed = await router.route(for: .sensitiveLocalOnly, projectID: pid)
        XCTAssertEqual(routed, ASRRouter.defaultRoutes[.sensitiveLocalOnly])
    }
}
