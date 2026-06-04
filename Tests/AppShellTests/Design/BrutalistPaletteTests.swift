import SwiftUI
import XCTest

@testable import AppShell

final class BrutalistPaletteTests: XCTestCase {
    func testDarkBackgroundIsTokenZero() {
        let p = BrutalistPalette.dark
        let bg = p.background.nsColor
        XCTAssertEqual(bg.redComponent, 0x0a / 255.0, accuracy: 0.005)
        XCTAssertEqual(bg.greenComponent, 0x0a / 255.0, accuracy: 0.005)
        XCTAssertEqual(bg.blueComponent, 0x0a / 255.0, accuracy: 0.005)
    }

    func testLightBackgroundIsFAFAFA() {
        let p = BrutalistPalette.light
        let bg = p.background.nsColor
        XCTAssertEqual(bg.redComponent, 0xfa / 255.0, accuracy: 0.005)
    }

    func testPrimaryOrangeIsFF3300InBothModes() {
        XCTAssertEqual(BrutalistPalette.dark.primary.hex, "#ff3300")
        XCTAssertEqual(BrutalistPalette.light.primary.hex, "#ff3300")
    }

    func testTokensLoadFromBundledJSON() throws {
        let loaded = try BrutalistPalette.loadFromBundle()
        XCTAssertEqual(loaded.dark.primary.hex, "#ff3300")
        XCTAssertEqual(loaded.dark.background.hex, "#0a0a0a")
        XCTAssertEqual(loaded.dark.bgCard.hex, "#181818")
        XCTAssertEqual(loaded.dark.fg.hex, "#e8e8e8")
    }
}

final class SettingsTabTests: XCTestCase {
    func testTabsCoverAllSections() {
        let tabs = SettingsTab.allCases
        // Consolidated from 16 → 12: Dictionary, Audio Devices, Calendar,
        // Accessibility/Paste and Watched Folders were merged away (Calendar +
        // Watched Folders + Accessibility now live under a single Integrations tab).
        XCTAssertEqual(tabs.count, 12)
        let sections = Set(tabs.map(\.section))
        XCTAssertEqual(sections, ["General", "Voice", "Intelligence", "Integrations", "About"])
    }
}

@MainActor
final class OnboardingStepTests: XCTestCase {
    func testSevenStepsInOrder() {
        let steps = OnboardingStateModel.Step.allCases
        XCTAssertEqual(steps.count, 7)
        XCTAssertEqual(steps.first, .welcome)
        XCTAssertEqual(steps.last, .done)
    }
}
