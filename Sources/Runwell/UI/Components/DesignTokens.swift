import SwiftUI

/// The visual vocabulary of the app, in one place.
///
/// These values were previously written inline at each call site, and had drifted:
/// the same card surface appeared with four different opacities, two corner radii
/// and two padding values. None of that variation was a decision. Naming the
/// surfaces makes a card look like a card everywhere, and makes a deliberate
/// difference legible as deliberate.
///
/// The scale, typography and motion are shared with Tidely (drop-sort) so the two
/// apps read as the same product. The older four-step spacing names and the two
/// radii Runwell already used are kept as aliases onto the shared scale rather than
/// being removed, so existing screens keep compiling while they are migrated.
///
/// Section 8.5 still governs meaning: these tokens carry no severity information,
/// because severity must never be conveyed by colour alone.
enum Theme {
    /// A 4pt base scale.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48

        /// Runwell's original names, mapped onto the shared scale.
        static let tight = xs
        static let row = sm
        static let card = md
        static let section = xl
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999

        /// Runwell's original names.
        static let small = sm
        static let card = md
    }

    enum Colors {
        static let accent = Color.accentColor
        static let cardBackground = Color(nsColor: .controlBackgroundColor)
        /// Only for places that genuinely need to hide what is behind them — a
        /// pinned header, say. Do not use it to fill the window or the sidebar:
        /// that paints over the system material and loses the translucency.
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let cardBorder = Color.primary.opacity(0.08)
        static let separator = Color.primary.opacity(0.06)
        static let subtleText = Color.secondary
        static let faintText = Color.secondary.opacity(0.7)

        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let info = Color.blue

        /// Reserved for the single most important highlight on a screen.
        static let highlightGradient = LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// The soft multi-colour wash behind onboarding and the Overview hero.
        /// Shared so both screens read as the same product.
        static let heroWash = LinearGradient(
            colors: [
                .blue.opacity(0.55),
                .cyan.opacity(0.35),
                .purple.opacity(0.40)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The rounded faces are most of the app's character: a plain system title
    /// reads as a stock macOS dialog, the rounded one as this product.
    enum Typography {
        static let largeTitle = Font.system(size: 26, weight: .bold, design: .rounded)
        static let title = Font.system(size: 19, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let callout = Font.system(size: 12, weight: .regular)
        static let caption = Font.system(size: 11, weight: .medium)
        static let metricNumber = Font.system(size: 30, weight: .bold, design: .rounded)
    }

    enum Motion {
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)
        static let quickSpring = Animation.spring(response: 0.25, dampingFraction: 0.85)
        static let easeCard = Animation.easeOut(duration: 0.18)
    }

    /// Layered surfaces built on `.quaternary` rather than a fixed colour: the
    /// hierarchical styles adapt to light and dark *and* to the material behind
    /// them, which a literal `Color.primary.opacity(_:)` does not.
    enum Surface {
        static let cardOpacity: Double = 0.3
        static let raisedOpacity: Double = 0.45
    }
}

// MARK: - Reusable card container

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.Colors.cardBackground,
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Colors.cardBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Section heading

struct SectionHeading: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Typography.title)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
        }
    }
}

// MARK: - Hover highlight

struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = Theme.Radius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .onHover { hovering = $0 }
            .animation(Theme.Motion.easeCard, value: hovering)
    }
}

extension View {
    /// The standard card: one padding, one radius, one fill, everywhere.
    func cardSurface(raised: Bool = false) -> some View {
        padding(Theme.Spacing.md)
            .background(
                .quaternary.opacity(raised ? Theme.Surface.raisedOpacity
                                           : Theme.Surface.cardOpacity),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
    }

    func hoverHighlight(radius: CGFloat = Theme.Radius.md) -> some View {
        modifier(HoverHighlight(radius: radius))
    }
}
