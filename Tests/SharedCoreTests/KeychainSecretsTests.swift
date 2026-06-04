import XCTest

@testable import SharedCore

final class KeychainSecretsTests: XCTestCase {

    private let testService = "app.trace.tests"
    private let testAccount = "test-account-\(UUID().uuidString.prefix(8))"

    override func tearDown() {
        // Best-effort cleanup in case a test failed partway through.
        try? KeychainSecrets(service: testService).delete(account: testAccount)
        super.tearDown()
    }

    func testSaveAndLoadString() throws {
        let kc = KeychainSecrets(service: testService)
        try kc.save(account: testAccount, value: "sk-test-abc123")
        let loaded = try kc.load(account: testAccount)
        XCTAssertEqual(loaded, "sk-test-abc123")
    }

    func testOverwriteExistingValue() throws {
        let kc = KeychainSecrets(service: testService)
        try kc.save(account: testAccount, value: "v1")
        try kc.save(account: testAccount, value: "v2")
        XCTAssertEqual(try kc.load(account: testAccount), "v2")
    }

    func testLoadMissingReturnsNil() throws {
        let kc = KeychainSecrets(service: testService)
        let unknown = "missing-\(UUID().uuidString.prefix(8))"
        let result = try kc.load(account: unknown)
        XCTAssertNil(result)
    }

    func testDeleteRemovesValue() throws {
        let kc = KeychainSecrets(service: testService)
        try kc.save(account: testAccount, value: "doomed")
        try kc.delete(account: testAccount)
        XCTAssertNil(try kc.load(account: testAccount))
    }

    func testEmptyValueRoundTrips() throws {
        let kc = KeychainSecrets(service: testService)
        try kc.save(account: testAccount, value: "")
        XCTAssertEqual(try kc.load(account: testAccount), "")
    }
}
