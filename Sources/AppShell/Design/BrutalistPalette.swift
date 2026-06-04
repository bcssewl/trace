import AppKit
import Foundation
import SharedCore
import SwiftUI

public struct BrutalistColor: Sendable, Equatable {
    public let hex: String
    public let color: Color
    public let nsColor: NSColor

    public init(hex: String, color: Color, nsColor: NSColor) {
        self.hex = hex.lowercased()
        self.color = color
        self.nsColor = nsColor
    }

    public static func hex(_ raw: String) -> BrutalistColor {
        let cleaned = raw.replacingOccurrences(of: "#", with: "")
        precondition(cleaned.count == 6, "BrutalistColor.hex expects #RRGGBB; got \(raw)")
        let r = Int(cleaned.prefix(2), radix: 16) ?? 0
        let g = Int(cleaned.dropFirst(2).prefix(2), radix: 16) ?? 0
        let b = Int(cleaned.dropFirst(4).prefix(2), radix: 16) ?? 0
        let ns = NSColor(
            srgbRed: Double(r) / 255.0, green: Double(g) / 255.0,
            blue: Double(b) / 255.0, alpha: 1.0
        )
        let c = Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
        return BrutalistColor(hex: "#" + cleaned, color: c, nsColor: ns)
    }

    public static func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> BrutalistColor {
        let ns = NSColor(
            srgbRed: Double(r) / 255.0, green: Double(g) / 255.0,
            blue: Double(b) / 255.0, alpha: a
        )
        let c = Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0).opacity(a)
        let hex = String(format: "#%02x%02x%02x%02x", r, g, b, Int(a * 255))
        return BrutalistColor(hex: hex, color: c, nsColor: ns)
    }
}

public struct BrutalistPalette: Sendable, Equatable {
    public let background: BrutalistColor
    public let bgCard: BrutalistColor
    public let bgTertiary: BrutalistColor
    public let fg: BrutalistColor
    public let fgMuted: BrutalistColor
    public let fgSidebar: BrutalistColor
    public let secondary: BrutalistColor
    public let accentBg: BrutalistColor
    public let border: BrutalistColor
    public let borderSoft: BrutalistColor
    public let primary: BrutalistColor
    public let highlightMatch: BrutalistColor
    public let highlightActive: BrutalistColor

    public init(
        background: BrutalistColor, bgCard: BrutalistColor, bgTertiary: BrutalistColor,
        fg: BrutalistColor, fgMuted: BrutalistColor, fgSidebar: BrutalistColor,
        secondary: BrutalistColor, accentBg: BrutalistColor, border: BrutalistColor,
        borderSoft: BrutalistColor, primary: BrutalistColor,
        highlightMatch: BrutalistColor, highlightActive: BrutalistColor
    ) {
        self.background = background
        self.bgCard = bgCard
        self.bgTertiary = bgTertiary
        self.fg = fg
        self.fgMuted = fgMuted
        self.fgSidebar = fgSidebar
        self.secondary = secondary
        self.accentBg = accentBg
        self.border = border
        self.borderSoft = borderSoft
        self.primary = primary
        self.highlightMatch = highlightMatch
        self.highlightActive = highlightActive
    }

    public static let dark = BrutalistPalette(
        background: .hex("#0a0a0a"), bgCard: .hex("#181818"), bgTertiary: .hex("#080808"),
        fg: .hex("#e8e8e8"), fgMuted: .hex("#7a7a7a"), fgSidebar: .hex("#bdbdbd"),
        secondary: .hex("#1f1f1f"), accentBg: .hex("#2e2e2e"), border: .hex("#2e2e2e"),
        borderSoft: .hex("#1f1f1f"), primary: .hex("#ff3300"),
        highlightMatch: .rgba(255, 51, 0, 0.18), highlightActive: .rgba(255, 51, 0, 0.42)
    )

    public static let light = BrutalistPalette(
        background: .hex("#fafafa"), bgCard: .hex("#ffffff"), bgTertiary: .hex("#f0f0f0"),
        fg: .hex("#0a0a0a"), fgMuted: .hex("#6e6e6e"), fgSidebar: .hex("#2e2e2e"),
        secondary: .hex("#ededed"), accentBg: .hex("#dcdcdc"), border: .hex("#dcdcdc"),
        borderSoft: .hex("#ededed"), primary: .hex("#ff3300"),
        highlightMatch: .rgba(255, 51, 0, 0.18), highlightActive: .rgba(255, 51, 0, 0.42)
    )

    public struct Pair: Sendable {
        public let dark: BrutalistPalette
        public let light: BrutalistPalette
        public func resolve(_ scheme: ColorScheme) -> BrutalistPalette {
            scheme == .light ? light : dark
        }
    }

    // ── Semantic status colors ──────────────────────────────────────────
    /// Status tints (success / info / warning) used by banners, status chips,
    /// and the coach's grounded/AI/nudge accents.
    ///
    /// These are intentionally *not*
    /// part of the per-theme `BrutalistPalette` struct (which is brand-neutral
    /// chrome) — they live here as light/dark pairs and are resolved the same
    /// way the palette is, via `resolve(_:)`. Values match Apple's system
    /// green/blue/orange so they read correctly in both schemes, replacing the
    /// ad-hoc inline `Color(red:…)` greens/blues/ambers in the coach + onboarding.
    public struct SemanticColors: Sendable, Equatable {
        public let success: BrutalistColor
        public let info: BrutalistColor
        public let warning: BrutalistColor

        public init(success: BrutalistColor, info: BrutalistColor, warning: BrutalistColor) {
            self.success = success
            self.info = info
            self.warning = warning
        }

        /// systemGreen / systemBlue / systemOrange — dark-scheme variants.
        public static let dark = SemanticColors(
            success: .hex("#32d74b"),
            info: .hex("#0a84ff"),
            warning: .hex("#ff9f0a")
        )

        /// systemGreen / systemBlue / systemOrange — light-scheme variants.
        public static let light = SemanticColors(
            success: .hex("#34c759"),
            info: .hex("#007aff"),
            warning: .hex("#ff9500")
        )

        public static func resolve(_ scheme: ColorScheme) -> SemanticColors {
            scheme == .light ? light : dark
        }
    }

    /// Convenience accessor mirroring `SemanticColors.resolve` so callers that
    /// already hold a resolved palette can stay symmetrical, e.g.
    /// `BrutalistPalette.semantic(scheme).success.color`.
    public static func semantic(_ scheme: ColorScheme) -> SemanticColors {
        SemanticColors.resolve(scheme)
    }

    public static func loadFromBundle() throws -> Pair {
        guard let url = Bundle.module.url(forResource: "BrutalistTokens", withExtension: "json") else {
            throw TraceError.configInvalid(
                field: "brutalist.tokens",
                reason: "BrutalistTokens.json missing from bundle"
            )
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(BrutalistTokenDocument.self, from: data)
        return Pair(dark: decoded.toPalette(), light: .light)
    }
}

private struct BrutalistTokenDocument: Decodable {
    struct UI: Decodable {
        let background: String
        let card: String
        let tertiary: String
        let foreground: String
        let mutedForeground: String
        let sidebarForeground: String
        let secondary: String
        let accent: String
        let border: String
        let sidebarBorder: String
        let primary: String
        let highlightMatch: String
        let highlightActive: String
    }
    let ui: UI

    func toPalette() -> BrutalistPalette {
        BrutalistPalette(
            background: .hex(ui.background), bgCard: .hex(ui.card),
            bgTertiary: .hex(ui.tertiary), fg: .hex(ui.foreground),
            fgMuted: .hex(ui.mutedForeground), fgSidebar: .hex(ui.sidebarForeground),
            secondary: .hex(ui.secondary), accentBg: .hex(ui.accent),
            border: .hex(ui.border), borderSoft: .hex(ui.sidebarBorder),
            primary: .hex(ui.primary),
            highlightMatch: parseRgba(ui.highlightMatch),
            highlightActive: parseRgba(ui.highlightActive)
        )
    }

    private func parseRgba(_ s: String) -> BrutalistColor {
        let stripped =
            s
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = stripped.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
            let r = Int(parts[0]),
            let g = Int(parts[1]),
            let b = Int(parts[2]),
            let a = Double(parts[3])
        else {
            return BrutalistColor.hex("#000000")
        }
        return BrutalistColor.rgba(r, g, b, a)
    }
}

private struct BrutalistPaletteKey: EnvironmentKey {
    static let defaultValue: BrutalistPalette = .dark
}

extension EnvironmentValues {
    public var brutalistPalette: BrutalistPalette {
        get { self[BrutalistPaletteKey.self] }
        set { self[BrutalistPaletteKey.self] = newValue }
    }
}
