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
struct OnboardingView: View {
    let capabilities: CapabilitySet
    let onFinish: () -> Void

    @State private var page = 0
    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 44)

            footer
        }
        .frame(width: 560, height: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcomePage
        case 1: measurementPage
        default: capabilityPage
        }
    }

    // MARK: - Page 1

    private var welcomePage: some View {
        VStack(spacing: Theme.Spacing.section) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 46))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: Theme.Spacing.card) {
                Text("Runwell")
                    .font(.largeTitle.weight(.semibold))
                Text("Find out what is actually draining your battery.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.card) {
                bullet("gauge.with.dots.needle.bottom.50percent",
                       "See which apps use the most power, right now.")
                bullet("clock.arrow.circlepath",
                       "Look back at what drained the battery earlier today.")
                bullet("lock.fill",
                       "Everything stays on this Mac. No account, no analytics, no network.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.card) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .frame(width: 22)
            Text(text)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                Text("Every number says where it came from")
                    .font(.title2.weight(.semibold))
                Text("Most battery apps show you a single figure and leave you to trust it. Runwell will not show a number it could not actually read.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.card) {
                provenance(.measured, "Read straight from a system counter.")
                provenance(.derived, "Worked out from two or more measurements.")
                provenance(.estimated, "Inferred with a model. Treat as approximate.")
                provenance(.unavailable, "Shown as an em dash, never as a zero. macOS would not say.")
            }

            Text("That last one matters most: a missing reading is not the same as a reading of zero, so Runwell will not invent one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func provenance(_ provenance: MetricProvenance, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.card) {
            Text(provenance.badge)
                .font(.caption.weight(.medium))
                .padding(.horizontal, Theme.Spacing.row)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .frame(width: 96, alignment: .center)
            Text(meaning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Page 3

    /// What this particular Mac can supply, probed rather than promised. A desktop
    /// with no battery, or a machine whose energy counters read flat, should learn
    /// that here instead of wondering why a column is empty.
    private var capabilityPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                Text("What this Mac can report")
                    .font(.title2.weight(.semibold))
                Text("Checked on your hardware just now, not assumed.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                ForEach(reportedCollectors, id: \.self) { collector in
                    let available = capabilities.isAvailable(collector)
                    HStack(alignment: .top, spacing: Theme.Spacing.card) {
                        // Section 8.5: a symbol and words, never colour alone.
                        Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(collector.displayName)
                            if let reason = capabilities.status(collector)?.reason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if !capabilities.hasBattery {
                Text("This Mac has no battery, so Runwell runs as a resource monitor: energy per app still works, battery history does not.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Dots rather than "2 of 3": the count is not information anyone needs.
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel("Page \(page + 1) of \(pageCount)")

            Spacer()

            if page > 0 {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { page -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button(page == pageCount - 1 ? "Start monitoring" : "Continue") {
                if page == pageCount - 1 {
                    onFinish()
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.section)
        .background(.quaternary.opacity(0.2))
    }
}
