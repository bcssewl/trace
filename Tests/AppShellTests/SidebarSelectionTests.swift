import XCTest

import struct SharedCore.LibraryItem

@testable import AppShell

/// BAS-26: a keyword hit's "Open →" routes a non-meeting item to the sidebar
/// section that shows it.
///
/// Meetings deep-link via `.traceOpenMeeting` instead,
/// so `forLibraryItem` returns nil for them.
final class SidebarSelectionTests: XCTestCase {

    func testDictationRoutesToAllDictation() {
        XCTAssertEqual(SidebarSelection.forLibraryItem(source: .dictation, projectId: nil), .allDictation)
    }

    func testFileWithProjectRoutesToProjectFiles() {
        let pid = UUID()
        XCTAssertEqual(
            SidebarSelection.forLibraryItem(source: .file, projectId: pid.uuidString),
            .projectCategory(pid, .files)
        )
    }

    func testVoiceMemoWithProjectRoutesToProjectVoiceMemos() {
        let pid = UUID()
        XCTAssertEqual(
            SidebarSelection.forLibraryItem(source: .voiceMemo, projectId: pid.uuidString),
            .projectCategory(pid, .voiceMemos)
        )
    }

    func testFileWithoutProjectRoutesToAllFiles() {
        // BAS-22 added a global "All files" section; an unfiled file routes there.
        XCTAssertEqual(SidebarSelection.forLibraryItem(source: .file, projectId: nil), .allFiles)
    }

    func testVoiceMemoWithoutProjectRoutesToAllVoiceMemos() {
        XCTAssertEqual(SidebarSelection.forLibraryItem(source: .voiceMemo, projectId: nil), .allVoiceMemos)
    }

    func testMeetingHasNoSectionRoute() {
        // Meetings deep-link through the open-meeting notification, not section nav.
        XCTAssertNil(SidebarSelection.forLibraryItem(source: .meeting, projectId: "P1"))
    }
}
