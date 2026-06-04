import SwiftUI

/// The brutalist "selectable list row": a leading orange dot when active, a
/// title, an optional trailing detail, a subtle active fill, and a hairline
/// divider.
///
/// Shared by every list-style picker (transcription engine, notes/
/// cleanup provider, Ollama model) so the look stays identical in one place.
@MainActor
struct BrutalistSelectRow: View {
    @Environment(\.brutalistPalette) private var palette
    let title: String
    let detail: String
    let selected: Bool
    let showDivider: Bool
    /// Optional brand logo rendered just before the title (provider/model rows).
    ///
    /// Nil for non-brand rows (e.g. the deterministic fixer or generic engines).
    let logo: BrandLogo?
    let action: () -> Void

    init(
        title: String,
        detail: String = "",
        selected: Bool,
        showDivider: Bool = true,
        logo: BrandLogo? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.selected = selected
        self.showDivider = showDivider
        self.logo = logo
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(selected ? palette.primary.color : Color.clear)
                    .frame(width: 7, height: 7)
                    .frame(width: 16, alignment: .center)
                if let logo {
                    BrandLogoView(logo, size: 16)
                }
                Text(title)
                    .font(BrutalistTypography.label)
                    .foregroundStyle(selected ? palette.fg.color : palette.fgSidebar.color)
                Spacer(minLength: 12)
                if !detail.isEmpty {
                    Text(detail)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.secondary.color : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showDivider {
                    Rectangle()
                        .fill(palette.borderSoft.color)
                        .frame(height: BrutalistMetrics.hairline)
                        .padding(.leading, 14)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
