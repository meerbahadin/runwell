import SwiftUI
import RunwellKit

/// First run. Three pages, shown once.
///
/// The point is not a feature tour: it is to teach the one idea the rest of the app
/// depends on. Runwell distinguishes what it *measured* from what it *estimated*,
/// and refuses to show a number it could not read. A user who has not been told
/// that reads an em dash as a bug and "Estimated" as hedging.
///
/// The middle page is generated from this Mac's own capability probe rather than a
/// fixed list, so the promise made here is the one the app can actually keep.
///
/// The presentation — a floating card with a gradient hero above the copy — follows
/// the onboarding in Tidely (drop-sort), at the user's request. The content is
/// Runwell's own; only the shell is shared.
struct OnboardingView: View {
    let capabilities: CapabilitySet
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    private let pageCount = 3

    private var isLastPage: Bool { page == pageCount - 1 }

    var body: some View {
        VStack(spacing: 0) {
            card
                .frame(maxWidth: 520)
                .padding(Theme.Spacing.xxl)
        }
        // Sized here rather than left to the sheet: the card is content-height, so
        // without a frame the sheet collapses to it and the page-to-page height
        // change makes the window jump. A fixed height also keeps the hero's
        // proportions stable across the three pages.
        .frame(width: 620, height: 660)
        // The card floats on the window's own material; no opaque fill behind it.
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
    }

    private var card: some View {
        VStack(spacing: 0) {
            hero
            content
        }
        .background(Theme.Colors.cardBackground)
        // Clip the whole card once. The hero then runs edge-to-edge inside it and
        // inherits the card's corners, so no gradient can peek out past the fade.
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(Theme.Colors.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack {
            OnboardingGradient(page: page)
            heroContent
                .padding(Theme.Spacing.xl)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var heroContent: some View {
        switch page {
        case 0:
            // The app icon carries its own rounded-square shape and shadow, so it
            // is shown directly rather than inside a tile — nesting one squircle in
            // another reads as a mistake.
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            } else {
                FloatingTile(size: 84, radius: Theme.Radius.xl + 2) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }

        case 1:
            // The idea of the page, shown rather than described: a real reading
            // beside one the app refuses to invent.
            FloatingTile(size: 300, radius: Theme.Radius.lg, isWide: true) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Measured").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.08), in: Capsule())
                        Text("2.4 W").font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        Text("Unavailable").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.08), in: Capsule())
                        Text("—").font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }

        default:
            FloatingTile(size: 64, radius: Theme.Radius.xl - 2) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            currentPage

            HStack(alignment: .center) {
                primaryButton
                if page > 0 {
                    Button("Back") {
                        withAnimation(reduceMotion ? nil : Theme.Motion.spring) { page -= 1 }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.subtleText)
                }
                Spacer()
                PageDots(count: pageCount, current: page)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : Theme.Motion.spring, value: page)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case 0: welcomePage
        case 1: measurementPage
        default: capabilityPage
        }
    }

    private var primaryButton: some View {
        Button {
            if isLastPage { onFinish() }
            else { withAnimation(reduceMotion ? nil : Theme.Motion.spring) { page += 1 } }
        } label: {
            Text(isLastPage ? "Start monitoring" : "Continue")
                .font(Theme.Typography.body)
                .frame(minWidth: 96)
                .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Page 1

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Runwell")
                .font(Theme.Typography.largeTitle)
            Text("Find out what is actually draining your battery.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                bullet("gauge.with.dots.needle.bottom.50percent",
                       "See which apps use the most power, right now.")
                bullet("clock.arrow.circlepath",
                       "Look back at what drained the battery earlier today.")
                bullet("lock.fill",
                       "Everything stays on this Mac. No account, no analytics, no network.")
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .frame(width: 22)
            Text(text)
                .font(Theme.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Page 2

    /// The idea the whole app rests on. The badges themselves live in Diagnostics
    /// rather than beside every number — repeating "Derived" on each cell was
    /// clutter — but the distinction still governs what the app will and will not
    /// show, so it is worth stating once.
    private var measurementPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Every number says where it came from")
                .font(Theme.Typography.largeTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text("Most battery apps show a single figure and leave you to trust it. Runwell will not show a number it could not actually read.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                provenance(.measured, "Read straight from a system counter.")
                provenance(.derived, "Worked out from two or more measurements.")
                provenance(.estimated, "Inferred with a model. Treat as approximate.")
                provenance(.unavailable, "Shown as an em dash, never as a zero.")
            }
            .padding(.top, Theme.Spacing.xs)

            Text("That last one matters most: a missing reading is not the same as a reading of zero, so Runwell will not invent one.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func provenance(_ provenance: MetricProvenance, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(provenance.badge)
                .font(Theme.Typography.caption)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .frame(width: 96, alignment: .center)
            Text(meaning)
                .font(Theme.Typography.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Page 3

    /// What this particular Mac can supply, probed rather than promised. A desktop
    /// with no battery, or a machine whose energy counters read flat, should learn
    /// that here instead of wondering why a column is empty.
    private var capabilityPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("What this Mac can report")
                .font(Theme.Typography.largeTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text("Checked on your hardware just now, not assumed.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(reportedCollectors, id: \.self) { collector in
                    let available = capabilities.isAvailable(collector)
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        // Section 8.5: a symbol and words, never colour alone.
                        Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(collector.displayName).font(Theme.Typography.body)
                            if let reason = capabilities.status(collector)?.reason {
                                Text(reason)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.faintText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, Theme.Spacing.xs)

            if !capabilities.hasBattery {
                Text("This Mac has no battery, so Runwell runs as a resource monitor: energy per app still works, battery history does not.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// GPU is deliberately left out: both collectors are gated off pending a stable
    /// public interface, and listing two permanent "no" rows on the welcome screen
    /// would read as a broken app rather than an honest one.
    private var reportedCollectors: [Collector] {
        [.processEnergy, .processCPU, .processMemory, .processWakeups, .battery]
    }
}

// MARK: - Presentation

/// The soft multi-colour wash behind the hero, shifting hue per page.
private struct OnboardingGradient: View {
    let page: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var colors: [Color] {
        switch page % 3 {
        case 0: [.blue.opacity(0.55), .cyan.opacity(0.35), .purple.opacity(0.40)]
        case 1: [.cyan.opacity(0.45), .blue.opacity(0.40), .indigo.opacity(0.30)]
        default: [.purple.opacity(0.45), .blue.opacity(0.35), .cyan.opacity(0.30)]
        }
    }

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                // Fades the wash into the card body. The stops matter: the gradient
                // must reach the card colour *before* the bottom edge, otherwise a
                // band of colour is still visible where the hero meets the content
                // and the card's rounded corners clip it into visible slivers.
                // Fades to clear rather than to the card colour: the card is now
                // translucent, so fading to an opaque fill would leave a visibly
                // solid band where the hero meets the content.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: Theme.Colors.cardBackground.opacity(0.5), location: 0.80),
                        .init(color: Theme.Colors.cardBackground.opacity(0.7), location: 0.97)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: page)
    }
}

/// A white rounded tile floating on the gradient.
///
/// The tile stays white in both themes — it is a light object sitting on the wash,
/// not a themed surface. Its content is therefore forced to a dark foreground: a
/// theme-adaptive `.primary` would turn white in dark mode and disappear against
/// the tile.
private struct FloatingTile<Content: View>: View {
    var size: CGFloat
    var radius: CGFloat
    var isWide = false
    @ViewBuilder var content: () -> Content

    /// Near-black rather than pure black, so it reads as ink on the white tile.
    private static var inkColor: Color { Color(white: 0.12) }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.white)
            .frame(width: size, height: isWide ? 64 : size)
            .overlay(
                content()
                    .foregroundStyle(Self.inkColor)
                    .environment(\.colorScheme, .light)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
