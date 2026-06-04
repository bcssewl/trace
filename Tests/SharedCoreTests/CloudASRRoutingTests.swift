import XCTest

@testable import SharedCore

/// BAS-21 — the cloud ASR mapping that was missing: a route's engine identifier
/// (e.g. "groq", "volcengine") must resolve to a real `CloudASRBackend` with the
/// matching provider endpoint, and every provider must have a human label.
final class CloudASREndpointMappingTests: XCTestCase {
    func testEndpointsForEveryProviderRoundTrip() {
        for provider in CloudASRProvider.allCases {
            let endpoints = CloudASRBackend.endpoints(for: provider)
            XCTAssertEqual(endpoints.provider, provider, "endpoints(for:) must return the matching provider")
            XCTAssertFalse(endpoints.keychainAccount.isEmpty)
        }
    }

    func testEndpointsForKnownProvidersUseExpectedAccounts() {
        XCTAssertEqual(CloudASRBackend.endpoints(for: .groq).keychainAccount, "groq")
        XCTAssertEqual(CloudASRBackend.endpoints(for: .volcengine).keychainAccount, "volcengine")
        XCTAssertEqual(CloudASRBackend.endpoints(for: .openai).keychainAccount, "openai")
    }

    func testEveryProviderHasDisplayName() {
        for provider in CloudASRProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) needs a display name")
        }
    }
}

/// BAS-21 — the resolver factory.
///
/// Previously the route→backend switch lived
/// privately inside `RuntimeASRBackendResolver` and only built local engines, so
/// cloud routes silently fell through to `nil` → Apple Speech. Extracted to a
/// pure, testable factory in SharedCore.
final class ASRBackendFactoryTests: XCTestCase {
    func testBuildsLocalBackends() {
        XCTAssertTrue(
            ASRBackendFactory.makeBackend(for: route("parakeet", cloud: false)) is ParakeetBackend)
        XCTAssertTrue(
            ASRBackendFactory.makeBackend(for: route("whisperkit", cloud: false)) is WhisperKitBackend)
        XCTAssertTrue(
            ASRBackendFactory.makeBackend(for: route("qwen3", cloud: false)) is Qwen3Backend)
        XCTAssertTrue(
            ASRBackendFactory.makeBackend(for: route("apple-speech", cloud: false)) is AppleSpeechBackend)
    }

    func testBuildsCloudBackendForCloudRoute() {
        let backend = ASRBackendFactory.makeBackend(for: route("groq", cloud: true))
        XCTAssertTrue(backend is CloudASRBackend)
    }

    func testEveryCloudProviderRouteResolvesToCloudBackend() {
        for provider in CloudASRProvider.allCases {
            let backend = ASRBackendFactory.makeBackend(for: route(provider.rawValue, cloud: true))
            XCTAssertTrue(backend is CloudASRBackend, "\(provider.rawValue) route must build a CloudASRBackend")
        }
    }

    func testRefusesCloudWhenAllowsCloudIsFalse() {
        // A cloud provider identifier with allowsCloud=false must NOT build a
        // cloud backend — this is the sensitive/local-only guard.
        XCTAssertNil(ASRBackendFactory.makeBackend(for: route("groq", cloud: false)))
    }

    func testReturnsNilForUnknownEngine() {
        XCTAssertNil(ASRBackendFactory.makeBackend(for: route("bogus-engine", cloud: true)))
    }

    private func route(_ engine: String, cloud: Bool) -> ASRRoute {
        ASRRoute(engineIdentifier: engine, modelIdentifier: "test-model", allowsCloud: cloud)
    }
}
