import SharedCore
import XCTest

@testable import AppShell

/// The permission catalogue is the single source of truth shared by onboarding
/// and the Permissions settings panel. These guard against a new
/// `PermissionRequester.Kind` being added without a catalogue entry (which would
/// silently drop it from both UIs) and against the launch-critical set drifting.
final class PermissionCatalogTests: XCTestCase {
    func testCatalogCoversEveryPermissionKindExactlyOnce() {
        let kinds = PermissionCatalog.all.map(\.kind)
        XCTAssertEqual(
            Set(kinds), Set(PermissionRequester.Kind.allCases),
            "Every PermissionRequester.Kind must have exactly one catalogue entry")
        XCTAssertEqual(kinds.count, PermissionRequester.Kind.allCases.count, "No duplicate catalogue entries")
    }

    func testGroupsPartitionTheCatalog() {
        let grouped = PermissionGroup.allGroupsForTest.flatMap { PermissionCatalog.group($0) }
        XCTAssertEqual(
            Set(grouped.map(\.kind)), Set(PermissionCatalog.all.map(\.kind)),
            "Core + meetings + optional groups must together cover the whole catalogue")
    }

    func testLaunchCriticalIsMicAccessibilityAndSystemAudio() {
        XCTAssertEqual(
            Set(PermissionCatalog.launchCritical),
            Set([.microphone, .accessibility, .systemAudio]),
            "Launch verification must cover exactly the silently-breaking permissions")
        // Every launch-critical permission must exist in the catalogue.
        for kind in PermissionCatalog.launchCritical {
            XCTAssertTrue(PermissionCatalog.all.contains { $0.kind == kind }, "\(kind) missing from catalogue")
        }
    }

    func testCoreAndMeetingPermissionsAreNonEmptyWithDescriptions() {
        XCTAssertFalse(PermissionCatalog.group(.core).isEmpty)
        XCTAssertFalse(PermissionCatalog.group(.meetings).isEmpty)
        for entry in PermissionCatalog.all {
            XCTAssertFalse(entry.name.isEmpty, "\(entry.kind) needs a name")
            XCTAssertFalse(entry.why.isEmpty, "\(entry.kind) needs a description")
        }
    }
}

extension PermissionGroup {
    /// Test-only enumeration of the groups (the production type intentionally
    /// isn't CaseIterable — nothing else needs to iterate it).
    static var allGroupsForTest: [PermissionGroup] { [.core, .meetings, .optional] }
}
