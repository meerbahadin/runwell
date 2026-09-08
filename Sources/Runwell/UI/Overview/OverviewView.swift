import SwiftUI
import RunwellKit

/// Section 8.1. Battery state, measured app energy coverage and the top drains.
///
/// Section 1.4 target: a user identifies the dominant measured application-energy
/// consumer within 10 seconds of opening the app — so that answer is the largest
/// thing on this screen.
struct OverviewView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Result of the last quit attempt, so a refusal is explained rather than
    /// looking like the button did nothing.
    @State private var quitOutcome: ProcessActionService.GroupOutcome?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                batterySection
                Divider()
                topDrainSection
                Divider()
                coverageSection
                // The divider lives inside the section so it disappears along with
                // it: with no insights, a trailing rule would fence off nothing.
                insightsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
        // A quit that was partly or wholly refused must say so: the policy protects
        // system processes and Runwell itself, and silence would read as a bug.
        .alert(
            "Quit result",
            isPresented: Binding(
                get: { quitOutcome != nil },
                set: { if !$0 { quitOutcome = nil } }
            ),
            presenting: quitOutcome
        ) { _ in
            Button("OK") { quitOutcome = nil }
        } message: { outcome in
            Text(quitSummary(outcome))
        }
    }

    // MARK: - Insights

    /// Section 8.3. The insights sit below the measurements: the numbers are the
    /// reason to trust them, so a reader arrives at a claim about an app having
    /// already seen the battery state, the drains and how much of the system's
    /// energy Runwell can actually account for.
    @ViewBuilder
    private var insightsSection: some View {
        if !environment.insights.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                ForEach(environment.insights) { insight in
                    let group = environment.group(for: insight)
                    // Only offer to quit what the policy actually permits: a group
                    // whose every process is protected would present a button that
                    // could not work.
                    let quittable = group.map { candidate in
                        candidate.members.contains {
                            !environment.actions.protection(for: $0.identity).isBlocked
                        }
                    } ?? false
                    InsightRow(
                        insight: insight,
                        onIgnore: { environment.mute(insight) },
                        group: quittable ? group : nil,
                        onQuit: quittable && group != nil
                            ? { force in
                                quitOutcome = force
                                    ? environment.actions.forceQuitGroup(group!, userConfirmed: true)
                                    : environment.actions.quitGroup(group!)
                            }
                            : nil
                    )
                }
            }
            Divider()
        }
    }

    /// Plain account of what happened, including what was refused and why.
    private func quitSummary(_ outcome: ProcessActionService.GroupOutcome) -> String {
        var parts: [String] = []
        if !outcome.terminated.isEmpty {
            parts.append("Quit \(outcome.terminated.count == 1 ? "1 process" : "\(outcome.terminated.count) processes").")
        }
        if outcome.alreadyGone > 0 {
            parts.append("\(outcome.alreadyGone) had already exited.")
        }
        for skipped in outcome.skipped {
            parts.append("\(skipped.name): \(skipped.reason)")
        }
        for failed in outcome.failed {
            parts.append("\(failed.name) did not quit: \(failed.reason)")
        }
        return parts.isEmpty ? "Nothing to quit." : parts.joined(separator: "\n")
    }

    // MARK: - Battery

    @ViewBuilder
    private var batterySection: some View {
        let battery = environment.snapshot?.battery

        VStack(alignment: .leading, spacing: 10) {
            Text("Battery")
                .font(.headline)

            if let battery, battery.isPresent {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(battery.percentage.formatted("%.0f", suffix: "%"))
                        .font(.system(size: 44, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 4) {
                        Label(stateDescription(battery), systemImage: stateSymbol(battery))
                            .font(.callout)
                        Text(timeDescription(battery))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            } else {
                // Section 2.3: desktop Macs run in resource-monitor mode. That is a
                // supported configuration, not an error.
                Label("No battery in this Mac — running as a resource monitor.",
                      systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateDescription(_ battery: BatterySnapshot) -> String {
        if battery.isCharged { return "Charged" }
        if battery.isCharging { return "Charging" }
        return battery.powerSource == .wallPower ? "On power adapter" : "On battery"
    }

    private func stateSymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharged { return "battery.100.bolt" }
        if battery.isCharging { return "battery.50.bolt" }
        return battery.powerSource == .wallPower ? "powerplug" : "battery.75"
    }

    private func timeDescription(_ battery: BatterySnapshot) -> String {
        guard let seconds = battery.timeRemaining.value else {
            // Never invent an estimate the OS did not give us (Section 3).
            if battery.isCharged { return "Fully charged" }
            // macOS itself withholds an estimate for the first few minutes after a
            // power-source change. Section 3: say who is unable to answer and why,
            // rather than implying Runwell is calculating something.
            return battery.powerSource == .wallPower ? "—" : "macOS has not estimated a time yet"
        }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let time = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return battery.isCharging ? "\(time) until full" : "\(time) remaining"
    }

    // MARK: - Top drain

    @ViewBuilder
    private var topDrainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Using the most energy")
                .font(.headline)

            if environment.isWaitingForFirstInterval {
                // Section 3: a rate needs two samples. Say so rather than showing zeros.
                Label("Measuring… energy needs two samples.", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if let top = environment.topEnergyGroup {
                HStack(spacing: 12) {
                    AppIcon(bundleURL: top.bundleURL, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(top.displayName)
                            .font(.title3.weight(.medium))
                        HStack(spacing: 6) {
                            MetricText(metric: top.totalEnergyWatts, format: "%.2f", suffix: " W")
                                .font(.callout)
                            if top.processCount > 1 {
                                Text("· \(top.processCount) processes")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let share = environment.snapshot?.coverage.measuredAppShare(of: top).value {
                            // Section 3.1 mandates this wording, not "battery used".
                            Text("\(EnergyCoverage.shareLabel): \(String(format: "%.0f%%", share * 100))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    StatusBadge(status: top.status)
                }
                .cardSurface(raised: true)
            } else {
                Label("No application is using measurable energy right now.",
                      systemImage: "leaf")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Coverage

    @ViewBuilder
    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measurement coverage")
                .font(.headline)

            // Section 3.1: the display, radios, DRAM and kernel work are not
            // attributable to any app, so this must never be presented as a full
            // account of battery discharge.
            Text("Runwell can measure energy for the processes it is allowed to read. The display, radios and system services are not included, so these shares describe applications only — not your whole battery.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let snapshot = environment.snapshot {
                let readable = snapshot.groups.reduce(0) { $0 + $1.processCount }
                let unreadable = snapshot.coverage.inaccessibleProcessCount
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Processes measured").foregroundStyle(.secondary)
                        Text("\(readable)").monospacedDigit()
                    }
                    GridRow {
                        Text("Not readable").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("\(unreadable)").monospacedDigit()
                            Text("system or other users")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Sampling").foregroundStyle(.secondary)
                        Text(snapshot.mode.description)
                    }
                }
                .font(.callout)
            }
        }
    }

}
