import XCTest

@testable import SharedCore

final class SyncWrappersTests: XCTestCase {
    func testSyncBoolReadWriteIsAtomic() {
        let flag = SyncBool(initial: false)
        XCTAssertFalse(flag.value)
        flag.value = true
        XCTAssertTrue(flag.value)
    }

    func testSyncBoolCompareAndSwap() {
        let flag = SyncBool(initial: false)
        XCTAssertTrue(flag.compareAndSwap(expected: false, desired: true))
        XCTAssertFalse(flag.compareAndSwap(expected: false, desired: true))
        XCTAssertTrue(flag.value)
    }

    func testSyncStringReadWrite() {
        let s = SyncString(initial: "hello")
        XCTAssertEqual(s.value, "hello")
        s.value = "world"
        XCTAssertEqual(s.value, "world")
    }

    func testSyncDictReadWrite() {
        let d = SyncDict<String, Int>(initial: ["a": 1])
        XCTAssertEqual(d.value["a"], 1)
        d.update { $0["b"] = 2 }
        XCTAssertEqual(d.value["b"], 2)
        XCTAssertEqual(d.value.count, 2)
    }

    func testSyncBoolConcurrentAccess() async {
        let flag = SyncBool(initial: false)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = flag.compareAndSwap(expected: false, desired: true)
                    _ = flag.value
                }
            }
        }
        XCTAssertTrue(flag.value)
    }
}
