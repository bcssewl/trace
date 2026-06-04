import Foundation
import XCTest
import os.lock

@testable import SharedCore

final class SyncStateLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[CaptureState]>(initialState: [])

    func append(_ state: CaptureState) {
        lock.withLock { $0.append(state) }
    }

    func snapshot() -> [CaptureState] {
        lock.withLock { $0 }
    }
}

final class CaptureStateTests: XCTestCase {
    func testIdleAndArmingAreNotTerminal() {
        XCTAssertFalse(CaptureState.idle.isTerminal)
        XCTAssertFalse(CaptureState.arming.isTerminal)
        XCTAssertFalse(CaptureState.recording.isTerminal)
        XCTAssertFalse(CaptureState.finalizing.isTerminal)
        XCTAssertFalse(CaptureState.cleaning.isTerminal)
        XCTAssertFalse(CaptureState.pasting.isTerminal)
    }

    func testDoneCancelledFailedAreTerminal() {
        XCTAssertTrue(CaptureState.done.isTerminal)
        XCTAssertTrue(CaptureState.cancelled.isTerminal)
        XCTAssertTrue(CaptureState.failed(reason: .asrFailed).isTerminal)
    }

    func testCodableRoundTrip() throws {
        let states: [CaptureState] = [
            .idle, .arming, .recording, .finalizing, .cleaning, .pasting,
            .done, .cancelled, .failed(reason: .permissionMissing),
        ]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        for s in states {
            let data = try enc.encode(s)
            let back = try dec.decode(CaptureState.self, from: data)
            XCTAssertEqual(s, back)
        }
    }
}

final class CaptureTransitionTests: XCTestCase {
    func testForwardArcIsPermitted() {
        XCTAssertTrue(CaptureTransition.isPermitted(from: .idle, to: .arming))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .arming, to: .recording))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .recording, to: .finalizing))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .finalizing, to: .cleaning))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .cleaning, to: .pasting))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .pasting, to: .done))
    }

    func testCancelFromAnyNonTerminalIsPermitted() {
        let active: [CaptureState] = [.arming, .recording, .finalizing, .cleaning, .pasting]
        for state in active {
            XCTAssertTrue(CaptureTransition.isPermitted(from: state, to: .cancelled))
        }
    }

    func testFailFromAnyNonTerminalIsPermitted() {
        let active: [CaptureState] = [.arming, .recording, .finalizing, .cleaning, .pasting]
        for state in active {
            XCTAssertTrue(CaptureTransition.isPermitted(from: state, to: .failed(reason: .asrFailed)))
        }
    }

    func testSkippingStepsIsRejected() {
        XCTAssertFalse(CaptureTransition.isPermitted(from: .idle, to: .recording))
        XCTAssertFalse(CaptureTransition.isPermitted(from: .arming, to: .cleaning))
        XCTAssertFalse(CaptureTransition.isPermitted(from: .recording, to: .pasting))
    }

    func testBackwardsTransitionsAreRejected() {
        XCTAssertFalse(CaptureTransition.isPermitted(from: .recording, to: .arming))
        XCTAssertFalse(CaptureTransition.isPermitted(from: .cleaning, to: .recording))
    }

    func testTerminalToIdleResets() {
        XCTAssertTrue(CaptureTransition.isPermitted(from: .done, to: .idle))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .cancelled, to: .idle))
        XCTAssertTrue(CaptureTransition.isPermitted(from: .failed(reason: .asrFailed), to: .idle))
    }

    func testTerminalCannotJumpForwards() {
        XCTAssertFalse(CaptureTransition.isPermitted(from: .done, to: .recording))
        XCTAssertFalse(CaptureTransition.isPermitted(from: .cancelled, to: .arming))
    }
}

final class CaptureStateMachineTests: XCTestCase {
    func testHappyPathSequence() async throws {
        let machine = CaptureStateMachine()
        try await machine.transition(to: .arming)
        try await machine.transition(to: .recording)
        try await machine.transition(to: .finalizing)
        try await machine.transition(to: .cleaning)
        try await machine.transition(to: .pasting)
        try await machine.transition(to: .done)
        let final = await machine.state
        XCTAssertEqual(final, .done)
    }

    func testIllegalTransitionThrows() async {
        let machine = CaptureStateMachine()
        do {
            try await machine.transition(to: .recording)
            XCTFail("expected throw")
        } catch let err as TraceError {
            guard case .configInvalid = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testObserverFiresOnEveryTransition() async throws {
        let machine = CaptureStateMachine()
        let collected = SyncStateLog()
        await machine.addObserver { state in
            collected.append(state)
        }
        try await machine.transition(to: .arming)
        try await machine.transition(to: .recording)
        try await machine.transition(to: .cancelled)
        XCTAssertEqual(collected.snapshot(), [.arming, .recording, .cancelled])
    }

    func testResetToIdleAfterTerminal() async throws {
        let machine = CaptureStateMachine()
        try await machine.transition(to: .arming)
        try await machine.transition(to: .failed(reason: .audioCaptureFailed))
        try await machine.resetToIdle()
        let state = await machine.state
        XCTAssertEqual(state, .idle)
    }

    func testResetIsNoOpWhenNotTerminal() async throws {
        let machine = CaptureStateMachine()
        try await machine.transition(to: .arming)
        try await machine.resetToIdle()
        let state = await machine.state
        XCTAssertEqual(state, .arming)
    }
}
