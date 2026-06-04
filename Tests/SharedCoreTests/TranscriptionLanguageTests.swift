import XCTest

@testable import SharedCore

/// BAS-74 — guards the transcription-language → locale mapping the runtimes thread
/// into `TranscriptionBackend.transcribe(_:locale:)`, plus the auto-detect sentinel
/// the WhisperKit / Apple Speech / cloud backends branch on.
final class TranscriptionLanguageTests: XCTestCase {
    func testAutoResolvesToDetectSentinel() {
        XCTAssertTrue(TranscriptionLanguage.auto.locale.isAutoDetect)
        // Engines that can't auto-detect fall back to the system locale.
        XCTAssertEqual(Locale.autoDetect.concreteOrCurrent, Locale.current)
    }

    func testExplicitLanguageMapsToConcreteLocale() {
        let zh = TranscriptionLanguage.mandarin.locale
        XCTAssertFalse(zh.isAutoDetect)
        XCTAssertEqual(zh.language.languageCode?.identifier, "zh")
        // A pinned language is passed through unchanged (not coerced to system).
        XCTAssertEqual(zh.concreteOrCurrent.language.languageCode?.identifier, "zh")
    }

    func testEverydayLanguagesAreNotAutoDetect() {
        for lang in TranscriptionLanguage.allCases where lang != .auto {
            XCTAssertFalse(lang.locale.isAutoDetect, "\(lang.rawValue) should be a concrete language")
        }
    }

    func testRawValuesAreWhisperLanguageCodes() {
        // The raw value doubles as Whisper's 2-letter code for non-auto cases.
        XCTAssertEqual(TranscriptionLanguage.mandarin.rawValue, "zh")
        XCTAssertEqual(TranscriptionLanguage.english.rawValue, "en")
        XCTAssertEqual(TranscriptionLanguage.japanese.rawValue, "ja")
    }
}
