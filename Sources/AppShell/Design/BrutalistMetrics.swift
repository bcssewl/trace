import CoreGraphics

public enum BrutalistMetrics {
    public static let sidebarMinWidth: CGFloat = 150
    public static let sidebarDefaultWidth: CGFloat = 180
    public static let sidebarMaxWidth: CGFloat = 250
    public static let inspectorWidth: CGFloat = 280
    public static let bottomStripHeight: CGFloat = 36
    public static let mainWindowMinSize = CGSize(width: 1200, height: 720)

    public static let notchCompactSize = CGSize(width: 200, height: 30)
    public static let notchWideSize = CGSize(width: 380, height: 30)
    public static let notchDropdownSize = CGSize(width: 420, height: 86)

    public static let coachWidth: CGFloat = 360
    public static let coachHeight: CGFloat = 540
    public static let coachDefaultHeight: CGFloat = 300
    public static let coachMinWidth: CGFloat = 280
    public static let coachMaxWidth: CGFloat = 560
    public static let coachMinHeight: CGFloat = 120
    public static let coachMaxHeight: CGFloat = 760
    public static let coachTopInset: CGFloat = 64
    public static let coachBottomInset: CGFloat = 24
    /// The compact pill is a small chip ("● Coach") by default.
    ///
    /// It is NOT
    /// resizable and its size is never persisted as the card frame. On hover it
    /// grows to reveal the Ask chips + expand affordance, then shrinks back.
    public static let coachPillWidth: CGFloat = 124
    public static let coachPillHeight: CGFloat = 34
    /// Expanded pill size while the mouse hovers the collapsed pill — wide enough
    /// to fit the four Ask chips on one row plus the expand affordance.
    public static let coachPillHoverWidth: CGFloat = 360
    public static let coachPillHoverHeight: CGFloat = 78
    /// Default card width/height used when there is no persisted card frame.
    public static let coachCardDefaultWidth: CGFloat = 360
    public static let coachCardDefaultHeight: CGFloat = 320

    public static let popoverCornerRadius: CGFloat = 10
    public static let notchCornerRadius: CGFloat = 14
    public static let coachCornerRadius: CGFloat = 12

    public static let indicatorDotSize: CGFloat = 6
    public static let pulsingDotSize: CGFloat = 8

    /// Single canonical opacity for "subtle accent tint" fills — the soft orange
    /// (brand `primary`) wash behind active chips, selected rows, banners, etc.
    ///
    /// Replaces ad-hoc 0.08 / 0.10 / 0.12 values scattered across views. This is
    /// a `Double` because it feeds `Color.opacity(_:)` directly.
    public static let accentTintOpacity: Double = 0.10

    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 24
    public static let space6: CGFloat = 32

    public static let hairline: CGFloat = 1
}
