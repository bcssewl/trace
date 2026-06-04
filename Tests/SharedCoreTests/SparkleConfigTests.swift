import XCTest

@testable import SharedCore

final class SparkleConfigTests: XCTestCase {

    func testFromBundleReturnsNilWhenKeysMissing() {
        // Bundle.module here is for SharedCoreTests itself; it lacks SUFeedURL
        // and SUPublicEDKey, so fromBundle should correctly return nil.
        XCTAssertNil(SparkleConfig.fromBundle(Bundle(for: SparkleConfigTests.self)))
    }

    func testFromBootstrapDefaultsValidates() throws {
        let defaults = BootstrapConfig.SparkleDefaults(
            feedURL: "https://example.com/appcast.xml",
            publicEDKey: "qwWBYgXiE4DD5RJrRfvkG6omXf1Ei7T46fgkcmI+IB8=",  // 32 bytes base64
            enableAutomaticChecks: false,
            scheduledCheckIntervalSeconds: 600
        )
        let config = try XCTUnwrap(SparkleConfig.from(defaults))
        XCTAssertEqual(config.feedURL.absoluteString, "https://example.com/appcast.xml")
        XCTAssertEqual(config.publicEDKey, defaults.publicEDKey)
        XCTAssertFalse(config.enableAutomaticChecks)
        XCTAssertEqual(config.scheduledCheckInterval, 600)
    }

    func testFromBootstrapDefaultsReturnsNilForInvalidURL() {
        let defaults = BootstrapConfig.SparkleDefaults(
            feedURL: "  ",  // whitespace causes URL parse failure
            publicEDKey: "anything",
            enableAutomaticChecks: true,
            scheduledCheckIntervalSeconds: 86_400
        )
        XCTAssertNil(SparkleConfig.from(defaults))
    }

    func testValidationAcceptsHTTPSAndValidKey() {
        let config = SparkleConfig(
            feedURL: URL(string: "https://updates.example.com/appcast.xml")!,
            publicEDKey: "qwWBYgXiE4DD5RJrRfvkG6omXf1Ei7T46fgkcmI+IB8=",
            enableAutomaticChecks: true,
            scheduledCheckInterval: 86_400
        )
        XCTAssertTrue(AppcastValidation.validate(config).isEmpty)
    }

    func testValidationRejectsHTTPFeed() {
        let config = SparkleConfig(
            feedURL: URL(string: "http://insecure.test/appcast.xml")!,
            publicEDKey: "qwWBYgXiE4DD5RJrRfvkG6omXf1Ei7T46fgkcmI+IB8=",
            enableAutomaticChecks: true,
            scheduledCheckInterval: 86_400
        )
        let failures = AppcastValidation.validate(config)
        XCTAssertTrue(failures.contains(.insecureFeedURL(host: "insecure.test")))
    }

    func testValidationRejectsPlaceholderKey() {
        let config = SparkleConfig(
            feedURL: URL(string: "https://example.com/appcast.xml")!,
            publicEDKey: "REPLACE_WITH_BASE64_PUBLIC_KEY_AT_RELEASE_TIME",
            enableAutomaticChecks: true,
            scheduledCheckInterval: 86_400
        )
        let failures = AppcastValidation.validate(config)
        XCTAssertTrue(failures.contains(.publicKeyPlaceholder))
    }

    func testValidationRejectsEmptyKey() {
        let config = SparkleConfig(
            feedURL: URL(string: "https://example.com/appcast.xml")!,
            publicEDKey: "",
            enableAutomaticChecks: true,
            scheduledCheckInterval: 86_400
        )
        let failures = AppcastValidation.validate(config)
        XCTAssertTrue(failures.contains(.publicKeyEmpty))
    }

    func testValidationRejectsMalformedKeyLength() {
        let config = SparkleConfig(
            feedURL: URL(string: "https://example.com/appcast.xml")!,
            publicEDKey: "tooshort",
            enableAutomaticChecks: true,
            scheduledCheckInterval: 86_400
        )
        let failures = AppcastValidation.validate(config)
        XCTAssertEqual(failures.count, 1)
        guard case .publicKeyMalformed = failures[0] else {
            XCTFail("expected publicKeyMalformed, got \(failures[0])")
            return
        }
    }

    func testValidationRejectsShortInterval() {
        let config = SparkleConfig(
            feedURL: URL(string: "https://example.com/appcast.xml")!,
            publicEDKey: "qwWBYgXiE4DD5RJrRfvkG6omXf1Ei7T46fgkcmI+IB8=",
            enableAutomaticChecks: true,
            scheduledCheckInterval: 30
        )
        let failures = AppcastValidation.validate(config)
        XCTAssertTrue(failures.contains(.scheduledCheckIntervalTooShort(30)))
    }
}
