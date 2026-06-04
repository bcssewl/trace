import XCTest

@testable import SharedCore

final class BridgesGlobalHotkeyTests: XCTestCase {
    func testRegisterStoresHandlerAndDispatchesByIdentifier() async throws {
        let registrar = StubCarbonHotkeyRegistrar()
        let center = GlobalHotkeyCenter(registrar: registrar)
        let id = HotkeyID("dictation.pushToTalk")
        let descriptor = HotkeyDescriptor(keyCode: 49, modifiers: [.option])

        let fired = AsyncExpectation()
        try await center.register(id: id, descriptor: descriptor) {
            Task { await fired.fulfill() }
        }
        await center.handleCarbonEvent(id: id)

        let didFire = await fired.waitWithTimeout(seconds: 1)
        XCTAssertTrue(didFire, "Handler should have fired")

        let registered = await registrar.snapshot()
        XCTAssertEqual(registered[id], descriptor)
    }
}

private actor StubCarbonHotkeyRegistrar: CarbonHotkeyRegistering {
    private var registered: [HotkeyID: HotkeyDescriptor] = [:]

    nonisolated func register(id: HotkeyID, descriptor: HotkeyDescriptor) throws {
        Task { await self.recordRegister(id: id, descriptor: descriptor) }
    }

    nonisolated func unregister(id: HotkeyID) {
        Task { await self.recordUnregister(id: id) }
    }

    private func recordRegister(id: HotkeyID, descriptor: HotkeyDescriptor) {
        registered[id] = descriptor
    }

    private func recordUnregister(id: HotkeyID) {
        registered[id] = nil
    }

    func snapshot() -> [HotkeyID: HotkeyDescriptor] { registered }
}

private actor AsyncExpectation {
    private var fulfilled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fulfill() {
        fulfilled = true
        continuation?.resume()
        continuation = nil
    }

    func waitWithTimeout(seconds: TimeInterval) async -> Bool {
        if fulfilled { return true }
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForever()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        return result
    }

    private func waitForever() async {
        if fulfilled { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.continuation = c
        }
    }
}
