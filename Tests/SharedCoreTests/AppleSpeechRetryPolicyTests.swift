import Foundation
import XCTest
import os

@testable import SharedCore

final class AppleSpeechRetryPolicyTests: XCTestCase {

    // MARK: - Backoff maths

    func testBackoffGrowsExponentiallyAndCaps() {
        let policy = AppleSpeechRetryPolicy(
            maxAttempts: 6, initialBackoff: 0.5, backoffMultiplier: 2, maxBackoff: 3)
        XCTAssertEqual(policy.backoff(beforeRetry: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(policy.backoff(beforeRetry: 2), 1.0, accuracy: 0.0001)
        XCTAssertEqual(policy.backoff(beforeRetry: 3), 2.0, accuracy: 0.0001)
        XCTAssertEqual(policy.backoff(beforeRetry: 4), 3.0, accuracy: 0.0001, "must cap at maxBackoff")
        XCTAssertEqual(policy.backoff(beforeRetry: 5), 3.0, accuracy: 0.0001)
    }

    func testMaxAttemptsFloorsAtOne() {
        let policy = AppleSpeechRetryPolicy(maxAttempts: 0)
        XCTAssertEqual(policy.maxAttempts, 1)
    }

    // MARK: - Rate-limit classification

    func testAssistantDomainRetryCodeIsRetryable() {
        let error = NSError(domain: "kAFAssistantErrorDomain", code: 203, userInfo: nil)
        XCTAssertTrue(AppleSpeechRetryPolicy.isRetryable(error))
    }

    func testRateLimitWordingIsRetryable() {
        for message in [
            "Rate limit exceeded for this client",
            "The service is throttling requests",
            "Too many requests, slow down",
            "Recognition server busy",
            "Service overloaded — please retry",
        ] {
            let error = NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
            XCTAssertTrue(AppleSpeechRetryPolicy.isRetryable(error), "should retry: \(message)")
        }
    }

    func testStructuralErrorsAreNotRetryable() {
        for message in [
            "on-device recognition unsupported for xx_YY",
            "buffer alloc failed",
            "The operation couldn't be completed",
        ] {
            let error = NSError(
                domain: "test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
            XCTAssertFalse(AppleSpeechRetryPolicy.isRetryable(error), "should not retry: \(message)")
        }
    }

    // MARK: - Request gate

    /// Requests run strictly one at a time, in submission order.
    func testGateSerialisesRequestsInFIFOOrder() async throws {
        let gate = AppleSpeechRequestGate()
        let order = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let active = OSAllocatedUnfairLock(initialState: 0)
        let maxActive = OSAllocatedUnfairLock(initialState: 0)

        var handles: [Task<Void, Error>] = []
        for i in 0..<5 {
            // Enqueue sequentially so the expected FIFO order is deterministic;
            // execution itself is what must be serialised.
            let handle = Task {
                try await gate.withTurn(minimumGap: 0) {
                    let now = active.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    maxActive.withLock { $0 = max($0, now) }
                    order.withLock { $0.append(i) }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    active.withLock { $0 -= 1 }
                }
            }
            // Give the task a beat to reach the gate before enqueueing the next.
            try await Task.sleep(nanoseconds: 20_000_000)
            handles.append(handle)
        }
        for handle in handles { _ = try await handle.value }

        XCTAssertEqual(order.withLock { $0 }, [0, 1, 2, 3, 4])
        XCTAssertEqual(maxActive.withLock { $0 }, 1, "requests must never overlap")
    }

    /// A failed request propagates its error AND releases the gate for the
    /// next request (no wedged queue).
    func testGateReleasesAfterFailure() async throws {
        let gate = AppleSpeechRequestGate()
        struct Boom: Error {}

        do {
            _ = try await gate.withTurn(minimumGap: 0) { () async throws -> Int in
                throw Boom()
            }
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }

        let value = try await gate.withTurn(minimumGap: 0) { 7 }
        XCTAssertEqual(value, 7)
    }

    /// Pacing: with a minimum gap configured, consecutive request STARTS are
    /// spaced at least that far apart.
    func testGateEnforcesMinimumRequestGap() async throws {
        let gate = AppleSpeechRequestGate()
        let clock = ContinuousClock()
        let starts = OSAllocatedUnfairLock<[ContinuousClock.Instant]>(initialState: [])

        for _ in 0..<3 {
            try await gate.withTurn(minimumGap: 0.1) {
                starts.withLock { $0.append(clock.now) }
            }
        }
        let recorded = starts.withLock { $0 }
        XCTAssertEqual(recorded.count, 3)
        for i in 1..<recorded.count {
            let gap = recorded[i] - recorded[i - 1]
            XCTAssertGreaterThanOrEqual(
                gap, .milliseconds(95),  // small scheduling tolerance
                "request starts must be paced apart")
        }
    }
}
