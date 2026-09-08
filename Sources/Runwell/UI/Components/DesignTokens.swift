import SwiftUI

/// The visual vocabulary of the app, in one place.
///
/// These values were previously written inline at each call site, and had drifted:
/// the same card surface appeared with four different opacities, two corner radii
/// and two padding values. None of that variation was a decision. Naming the
/// surfaces makes a card look like a card everywhere, and makes a deliberate
/// difference legible as deliberate.
///
/// Section 8.5 still governs meaning: these tokens carry no severity information,
/// because severity must never be conveyed by colour alone.
enum Theme {
    /// Corner radii, named by the size of the thing being rounded rather than by
    /// number, so a card and a bar cannot silently drift apart.
    enum Radius {
        /// Small inline elements: chart bars, swatches, capsule-adjacent shapes.
        static let small: CGFloat = 4
        /// The standard panel and card.
        static let card: CGFloat = 10
    }

    /// A four-step spacing scale. Anything not on the scale should be justified.
    enum Spacing {
        static let tight: CGFloat = 4
        static let row: CGFloat = 8
        static let card: CGFloat = 12
        static let section: CGFloat = 20
    }

    /// Layered surfaces. `card` is the default; `raised` is for content that sits
    /// on top of a card and needs to separate from it.
    ///
    /// Built on `.quaternary` rather than a fixed colour: the hierarchical styles
    /// adapt to light and dark *and* to the material behind them, which a literal
    /// `Color.primary.opacity(_:)` does not.
    enum Surface {
        static let cardOpacity: Double = 0.3
        static let raisedOpacity: Double = 0.45
    }
}

extension View {
    /// The standard card: one padding, one radius, one fill, everywhere.
    func cardSurface(raised: Bool = false) -> some View {
        padding(Theme.Spacing.card)
            .background(
                .quaternary.opacity(raised ? Theme.Surface.raisedOpacity
                                           : Theme.Surface.cardOpacity),
                in: RoundedRectangle(cornerRadius: Theme.Radius.card)
            )
    }
}
