import SwiftUI
import RunwellKit

/// One insight in the Overview list.
///
/// Extracted from `OverviewView` so the row's layout, hierarchy and affordances
/// live in one place rather than inline in a section builder.
struct InsightRow: View {
    let insight: Insight
    let onIgnore: () -> Void
    /// The running application this insight names, when it is still running. Nil
    /// means there is nothing to quit — the process has already gone.
    var group: ApplicationGroup?
    var onQuit: ((_ force: Bool) -> Void)?

    @State private var isHovering = false
    @State private var confirmingQuit = false

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
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.row)

            // Telling someone an app is draining their battery and offering no way
            // to act on it leaves them to hunt for it in Activity Monitor. The
            // protection policy still applies: system-owned processes and Runwell
            // itself refuse to be quit here as anywhere else.
            if let group, onQuit != nil {
                Button("Quit") { confirmingQuit = true }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .padding(.horizontal, Theme.Spacing.row)
                    .padding(.vertical, Theme.Spacing.tight)
                    .background(.quaternary.opacity(isHovering ? 0.5 : 0), in: Capsule())
                    .contentShape(Capsule())
                    .help("Quits \(group.displayName). Unsaved work may be lost.")
                    .accessibilityLabel("Quit \(group.displayName)")
                    .confirmationDialog(
                        "Quit \(group.displayName)?",
                        isPresented: $confirmingQuit, titleVisibility: .visible
                    ) {
                        Button("Quit", role: .destructive) { onQuit?(false) }
                        // Section 8.4: available, never the default.
                        Button("Force Quit", role: .destructive) { onQuit?(true) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(quitExplanation(group))
                    }
            }

            // Section 8.4 "Ignore alerts". Styled as secondary text before, which
            // gave no sign it could be clicked; it now reveals itself on hover.
            Button("Ignore", action: onIgnore)
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
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

    /// Says what quitting will actually do, including how many processes go with it:
    /// quitting "Chrome" closes every tab, and that should not be a surprise.
    private func quitExplanation(_ group: ApplicationGroup) -> String {
        let processes = group.processCount
        let scope = processes > 1
            ? "This closes all \(processes) of its processes. "
            : ""
        return scope + "Quit asks politely and may be ignored; Force Quit ends it immediately. Unsaved work may be lost."
    }
}
