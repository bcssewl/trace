import SharedCore
import XCTest

@testable import AppShell

/// The coach's cloud-only gate: it refuses to run unless `.coachCardContent`
/// is routed to a cloud provider whose credential is actually connected. The
/// coordinator turns a failed gate into the loud "The coach needs a cloud
/// model. Connect one in Settings → AI models." notice and does not start the
/// listener (and the manual trigger refuses the same way).
final class CoachCloudGateTests: XCTestCase {

    func testLocalProvidersNeverSatisfyTheGate() {
        let everythingConnected = Set(ModelProvider.keyedCloudProviders)
        for provider: DictationCleanupProvider in [.deterministic, .appleFM, .ollama] {
            XCTAssertFalse(
                CoachCloudGate.isSatisfied(provider: provider, connected: everythingConnected),
                "\(provider.rawValue) is local — the coach must refuse even with every cloud key present")
            XCTAssertFalse(provider.isCloudCapable)
        }
    }

    func testCloudProviderWithoutCredentialFailsTheGate() {
        for provider: DictationCleanupProvider in [.openRouter, .anthropic, .chatgpt, .minimax] {
            XCTAssertTrue(provider.isCloudCapable)
            XCTAssertFalse(
                CoachCloudGate.isSatisfied(provider: provider, connected: []),
                "\(provider.rawValue) without a key must fail the gate — loudly, upstream")
        }
    }

    func testConnectedCloudProviderSatisfiesTheGate() {
        XCTAssertTrue(CoachCloudGate.isSatisfied(provider: .openRouter, connected: [.openRouter]))
        XCTAssertTrue(CoachCloudGate.isSatisfied(provider: .anthropic, connected: [.anthropic, .openRouter]))
        // Connected ≠ this one connected.
        XCTAssertFalse(CoachCloudGate.isSatisfied(provider: .minimax, connected: [.openRouter]))
    }
}
