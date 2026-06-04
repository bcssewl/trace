import XCTest

@testable import AppShell

final class AppShellModuleTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(AppShell.moduleName, "AppShell")
    }
}
