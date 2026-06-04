import XCTest

@testable import FileBatchModule

final class FileBatchModuleTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(FileBatchModule.moduleName, "FileBatchModule")
    }
}
