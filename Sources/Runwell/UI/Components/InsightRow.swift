import SwiftUI
import RunwellKit

/// One insight in the Overview list.
///
/// Extracted from `OverviewView` so the row's layout, hierarchy and affordances
/// live in one place rather than inline in a section builder.
struct InsightRow: View {
    let insight: Insight
    let onIgnore: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.row + 2) {
            // Section 8.5: an icon and text, never colour alone.
            Image(systemName: insight.rule.symbolName)
                .foregroundStyle(insight.severity == .warning ? .orange : .secondary)
                .frame(width: 18)
                // The symbol reads as an icon, not as body text beside it.
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight - 1) {
                // The claim carries the weight; the evidence supports it. Previously
                // both were body text, so the row read as one flat block.
                Text(insight.message)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.row)

            // Section 8.4 "Ignore alerts". Styled as secondary text before, which
            // gave no sign it could be clicked; it now reveals itself on hover.
            Button("Ignore", action: onIgnore)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, Theme.Spacing.row)
                .padding(.vertical, Theme.Spacing.tight)
                .background(
                    .quaternary.opacity(isHovering ? 0.5 : 0),
                    in: Capsule()
                )
                .onHover { isHovering = $0 }
                .help("Stops this alert for this app. Measurement continues.")
                .accessibilityLabel("Ignore alerts for \(insight.appName)")
        }
        .cardSurface()
        // Motion stays subtle: a hover cue should not announce itself.
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
