import SwiftUI

// MARK: - Empty state

/// A centered "nothing here yet" placeholder: a light SF Symbol, a title, a
/// muted detail line, and an optional call-to-action button.
///
/// Standardized from
/// the local `emptyState` helper that used to live in PlaybooksView. Adopted by
/// the ~7 list/detail views that need an empty placeholder.
public struct BrutalistEmptyState: View {
    @Environment(\.brutalistPalette) private var palette
    public let symbol: String
    public let title: String
    public let detail: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: BrutalistMetrics.space4) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.fgMuted.color)
            Text(title)
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fgMuted.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                BrutalistButton(actionTitle, kind: .primary, action: action)
                    .padding(.top, BrutalistMetrics.space1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }
}

// MARK: - Page header

/// The standard page header — a large title plus a muted one-line blurb.
///
/// Modeled exactly on `SettingsDetailPane.header` (title + body, H32 / T28 / B18)
/// so main-window pages match the cleaned Settings chrome.
public struct BrutalistPageHeader: View {
    @Environment(\.brutalistPalette) private var palette
    public let title: String
    public let blurb: String

    public init(title: String, blurb: String) {
        self.title = title
        self.blurb = blurb
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrutalistMetrics.space1) {
            Text(title)
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text(blurb)
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, BrutalistMetrics.space6)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chip

/// A sentence-case, system-font bordered pill for filters / scopes / sources /
/// modes.
///
/// Replaces the old ALL-CAPS monospace pills in the Library/Meeting
/// views. When `active`, it picks up the brand-orange border + subtle accent
/// tint fill (`BrutalistMetrics.accentTintOpacity`).
public struct BrutalistChip: View {
    @Environment(\.brutalistPalette) private var palette
    public let text: String
    public let active: Bool

    public init(_ text: String, active: Bool = false) {
        self.text = text
        self.active = active
    }

    public var body: some View {
        Text(text)
            .font(BrutalistTypography.caption)
            .foregroundStyle(active ? palette.fg.color : palette.fgSidebar.color)
            .padding(.horizontal, BrutalistMetrics.space2)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? palette.primary.color.opacity(BrutalistMetrics.accentTintOpacity) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        active ? palette.primary.color : palette.border.color,
                        lineWidth: BrutalistMetrics.hairline
                    )
            )
    }
}

/// A small, borderless status label (Live / Final / Inserted) in system font,
/// tinted by a semantic color.
///
/// Pill-shaped with a faint tint wash so it reads
/// as a state badge, not a tappable chip.
public struct BrutalistStatusChip: View {
    public let text: String
    public let tint: Color

    public init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(BrutalistTypography.captionEmphasis)
            .foregroundStyle(tint)
            .padding(.horizontal, BrutalistMetrics.space2)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(BrutalistMetrics.accentTintOpacity))
            )
    }
}

// MARK: - Banner

/// The kind of a `BrutalistBanner`, selecting both the leading SF Symbol and
/// the accent tint (drawn from the semantic palette tokens).
public enum BrutalistBannerKind: Sendable {
    case info
    case warning
    case success

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .success: return "checkmark.circle"
        }
    }

    func tint(_ semantic: BrutalistPalette.SemanticColors) -> Color {
        switch self {
        case .info: return semantic.info.color
        case .warning: return semantic.warning.color
        case .success: return semantic.success.color
        }
    }
}

/// One canonical informational banner — a rounded-10 `bgCard` panel with a
/// leading SF Symbol (NOT a glyph baked into the title), a title, an optional
/// detail line, and an optional trailing action button.
///
/// Replaces the three
/// one-off banners (live / categorization / embedding). Tint comes from the
/// semantic palette tokens, so light/dark are handled automatically.
public struct BrutalistBanner: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    public let kind: BrutalistBannerKind
    public let title: String
    public let detail: String?
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        kind: BrutalistBannerKind,
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        let tint = kind.tint(BrutalistPalette.semantic(scheme))
        HStack(alignment: .top, spacing: BrutalistMetrics.space3) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: BrutalistMetrics.space1) {
                Text(title)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                if let detail {
                    Text(detail)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: BrutalistMetrics.space2)
            if let actionTitle, let action {
                BrutalistButton(actionTitle, kind: .ghost, size: .compact, action: action)
            }
        }
        .padding(BrutalistMetrics.space3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.bgCard.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.border.color, lineWidth: BrutalistMetrics.hairline)
        )
    }
}
