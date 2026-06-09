import AppKit
import SwiftUI

/// Renders the `AppNoticeCenter` queue as a stack of dismissible banners
/// pinned to the top of the main window — the visible half of the
/// no-silent-failure rule. Each banner carries the recovery buttons the
/// underlying error declared (open the right Settings tab, the right System
/// Settings pane, or a caller-supplied retry).
@MainActor
struct NoticeBannerStack: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme

    let center: AppNoticeCenter
    let appState: AppStateModel?

    /// Newest first; the rest stack beneath. Capped so a cascade of failures
    /// can't wallpaper the window — the overflow line says what's hidden.
    private static let visibleCap = 3

    var body: some View {
        let queue = Array(center.notices.reversed())
        if !queue.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(queue.prefix(Self.visibleCap)) { notice in
                    banner(notice)
                }
                if queue.count > Self.visibleCap {
                    overflowLine(hidden: queue.count - Self.visibleCap)
                }
            }
            .frame(maxWidth: 520, alignment: .trailing)
            .padding(.top, 52)  // beneath the toolbar strip
            .padding(.trailing, 16)
            .animation(.easeOut(duration: 0.18), value: center.notices.map(\.id))
        }
    }

    private func banner(_ notice: AppNoticeCenter.Notice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(tint(for: notice.severity))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.title)
                        .font(BrutalistTypography.labelEmphasis)
                        .foregroundStyle(palette.fg.color)
                    Spacer(minLength: 12)
                    Button {
                        center.dismiss(notice.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.fgMuted.color)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                Text(notice.message)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                if !notice.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(notice.actions) { action in
                            BrutalistButton(action.label, kind: .ghost) {
                                perform(action, dismissing: notice)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .background(palette.bgCard.color)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func overflowLine(hidden: Int) -> some View {
        HStack(spacing: 10) {
            Text(hidden == 1 ? "1 more notice" : "\(hidden) more notices")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
            BrutalistButton("Dismiss all", kind: .ghost) {
                center.dismissAll()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.bgCard.color)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tint(for severity: AppNoticeCenter.Notice.Severity) -> Color {
        let semantic = BrutalistPalette.SemanticColors.resolve(scheme)
        switch severity {
        case .info: return semantic.info.color
        case .warning: return semantic.warning.color
        case .error: return palette.primary.color
        }
    }

    private func perform(_ action: AppNoticeCenter.NoticeAction, dismissing notice: AppNoticeCenter.Notice) {
        switch action {
        case .openSettingsTab(let tab, _):
            appState?.pendingSettingsTab = tab
            NotificationCenter.default.post(name: .traceOpenSettingsTab, object: nil)
        case .openSystemSettings(let pane, _):
            if let url = AppNoticeCenter.NoticeAction.systemSettingsURL(pane: pane) {
                NSWorkspace.shared.open(url)
            }
        case .custom(_, let handler):
            handler()
        }
        center.dismiss(notice.id)
    }
}
