import SwiftUI

public struct BrutalistIndicatorDot: View {
    public let color: Color
    public let diameter: CGFloat

    public init(color: Color, diameter: CGFloat = BrutalistMetrics.indicatorDotSize) {
        self.color = color
        self.diameter = diameter
    }

    public var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: diameter, height: diameter)
    }
}

/// The single canonical pulsing dot.
///
/// A square (brutalist) mark whose opacity
/// breathes between 0.35 and 1.0. Takes `color` + `size` so it can stand in for
/// the near-identical `NotchPulsingDot` / `CoachPulsingDot` copies in the
/// controllers (those are circles; per-view passes will adopt this).
public struct BrutalistPulsingDot: View {
    public let color: Color
    public let size: CGFloat
    @State private var on: Bool = false

    public init(color: Color, size: CGFloat = BrutalistMetrics.pulsingDotSize) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

public struct BrutalistRow<Content: View>: View {
    @Environment(\.brutalistPalette) private var palette
    public let content: Content
    public let showDivider: Bool

    public init(showDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.showDivider = showDivider
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, BrutalistMetrics.space3)
                .padding(.vertical, BrutalistMetrics.space2)
            if showDivider {
                Rectangle()
                    .fill(palette.borderSoft.color)
                    .frame(height: BrutalistMetrics.hairline)
            }
        }
    }
}

public enum BrutalistButtonKind: Sendable {
    case primary
    case ghost
    case danger
}

/// Visual size of a `BrutalistButton`. `.regular` matches the historical
/// padding; `.compact` is for dense toolbars / inline affordances.
public enum BrutalistButtonSize: Sendable {
    case regular
    case compact

    var hPadding: CGFloat {
        switch self {
        case .regular: return BrutalistMetrics.space3
        case .compact: return BrutalistMetrics.space2
        }
    }

    var vPadding: CGFloat {
        switch self {
        case .regular: return BrutalistMetrics.space2
        case .compact: return BrutalistMetrics.space1
        }
    }
}

public struct BrutalistButton: View {
    @Environment(\.brutalistPalette) private var palette
    public let title: String
    public let kind: BrutalistButtonKind
    public let size: BrutalistButtonSize
    /// Optional leading SF Symbol.
    ///
    /// When set, renders before the title.
    public let systemImage: String?
    public let action: () -> Void

    public init(
        _ title: String,
        kind: BrutalistButtonKind = .ghost,
        size: BrutalistButtonSize = .regular,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.size = size
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: BrutalistMetrics.space1) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(BrutalistTypography.uiLabel)
                }
                Text(title)
                    .font(BrutalistTypography.uiLabel)
            }
            .padding(.horizontal, size.hPadding)
            .padding(.vertical, size.vPadding)
            .background(background)
            .foregroundStyle(foreground)
            .overlay(border)
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch kind {
        case .primary: return palette.primary.color
        case .ghost: return Color.clear
        case .danger: return Color.clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return palette.background.color
        case .ghost: return palette.fg.color
        case .danger: return palette.primary.color
        }
    }

    private var border: some View {
        Rectangle()
            .stroke(palette.border.color, lineWidth: BrutalistMetrics.hairline)
    }
}

/// A plain button style whose hover/press highlight is clipped to a rounded
/// rectangle — the macOS default `.plain` style draws a sharp full-bleed
/// highlight, which looks wrong on the app's rounded chrome.
///
/// This is the
/// shared port of the coach overlay's bespoke `CoachRoundedButtonStyle`, so
/// every view can get the same rounded affordance from one place.
public struct BrutalistRoundedButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var hoverFill: Color
    public var pressFill: Color

    public init(cornerRadius: CGFloat = 8, hoverFill: Color, pressFill: Color) {
        self.cornerRadius = cornerRadius
        self.hoverFill = hoverFill
        self.pressFill = pressFill
    }

    public func makeBody(configuration: Configuration) -> some View {
        // Hover state lives in a dedicated view so `@State` is reliably owned
        // per button instance (a ButtonStyle struct is a poor place for @State).
        Highlighted(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hoverFill: hoverFill,
            pressFill: pressFill
        )
    }

    private struct Highlighted: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let hoverFill: Color
        let pressFill: Color
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            return configuration.label
                .background(
                    shape.fill(
                        configuration.isPressed
                            ? pressFill
                            : (hovering ? hoverFill : Color.clear)
                    )
                )
                .contentShape(shape)
                .clipShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

extension View {
    /// A plain button whose hover/press highlight stays within `radius`.
    ///
    /// Derives its fills from `palette.fg` so it adapts to light/dark.
    public func brutalistRoundedButton(
        radius: CGFloat = 8,
        palette: BrutalistPalette
    ) -> some View {
        buttonStyle(
            BrutalistRoundedButtonStyle(
                cornerRadius: radius,
                hoverFill: palette.fg.color.opacity(0.08),
                pressFill: palette.fg.color.opacity(0.14)
            )
        )
    }
}

/// A compact, square, icon-only button with the shared rounded highlight.
///
/// For toolbar affordances (close, add, more, etc.) that previously used a
/// bare `Image` in a `.plain` button with a sharp highlight.
public struct BrutalistIconButton: View {
    @Environment(\.brutalistPalette) private var palette
    public let systemImage: String
    public let accessibilityLabel: String
    public let size: CGFloat
    public let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        size: CGFloat = 13,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(palette.fgMuted.color)
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
        }
        .brutalistRoundedButton(radius: 6, palette: palette)
        .accessibilityLabel(accessibilityLabel)
    }
}

public struct BrutalistTextField: View {
    @Environment(\.brutalistPalette) private var palette
    public let placeholder: String
    @Binding public var text: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(BrutalistTypography.uiBody)
            .padding(.horizontal, BrutalistMetrics.space3)
            .padding(.vertical, BrutalistMetrics.space2)
            .foregroundStyle(palette.fg.color)
            .background(palette.bgCard.color)
            .overlay(
                Rectangle().stroke(palette.border.color, lineWidth: BrutalistMetrics.hairline)
            )
    }
}

public struct BrutalistGlassPopover<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: BrutalistMetrics.popoverCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

public struct BrutalistSectionHeader: View {
    @Environment(\.brutalistPalette) private var palette
    public let title: String
    public let index: String?

    public init(_ title: String, index: String? = nil) {
        self.title = title
        self.index = index
    }

    public var body: some View {
        HStack(spacing: BrutalistMetrics.space2) {
            if let index {
                Text(index)
                    .font(BrutalistTypography.sectionIndex)
                    .foregroundStyle(palette.fgMuted.color)
            }
            Text(title.uppercased())
                .font(BrutalistTypography.sectionHeader)
                .foregroundStyle(palette.fg.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BrutalistMetrics.space3)
        .padding(.vertical, BrutalistMetrics.space2)
    }
}

public struct BrutalistToggle: View {
    @Environment(\.brutalistPalette) private var palette
    public let title: String
    @Binding public var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(BrutalistTypography.uiLabel)
                .foregroundStyle(palette.fg.color)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(palette.primary.color)
        }
    }
}

public struct BrutalistSlider: View {
    @Environment(\.brutalistPalette) private var palette
    public let title: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>

    public init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        self._value = value
        self.range = range
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrutalistMetrics.space1) {
            HStack {
                Text(title).font(BrutalistTypography.uiLabel).foregroundStyle(palette.fg.color)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fgMuted.color)
            }
            Slider(value: $value, in: range)
                .tint(palette.primary.color)
        }
    }
}

public struct BrutalistCallout: View {
    @Environment(\.brutalistPalette) private var palette
    public let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(alignment: .top, spacing: BrutalistMetrics.space2) {
            Rectangle()
                .fill(palette.primary.color)
                .frame(width: 2)
            Text(text)
                .font(BrutalistTypography.uiBody)
                .foregroundStyle(palette.fg.color)
                .padding(.vertical, BrutalistMetrics.space2)
            Spacer(minLength: 0)
        }
        .background(palette.bgCard.color)
    }
}

public struct BrutalistKbdLabel: View {
    @Environment(\.brutalistPalette) private var palette
    public let keys: [String]

    public init(_ keys: [String]) { self.keys = keys }

    public var body: some View {
        HStack(spacing: BrutalistMetrics.space1) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(BrutalistTypography.mono11)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(palette.secondary.color)
                    .foregroundStyle(palette.fg.color)
                    .overlay(Rectangle().stroke(palette.border.color, lineWidth: BrutalistMetrics.hairline))
            }
        }
    }
}
